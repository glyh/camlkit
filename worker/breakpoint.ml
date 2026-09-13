(* Stopping inside a running phrase, see docs/wayfinder/tickets/035.

   A stop is an effect, not a debugger. The phrase performs it, the handler
   around the phrase keeps the continuation, and evaluation returns to the
   request loop, so the session stays alive while the phrase is parked: a
   debuggee is frozen, this is not. Resuming is continuing the continuation,
   which is why a parked phrase is a value in a table rather than a blocked
   read, and why supervision needs to know nothing about any of this.

   Two halves live here. The runtime half is the effect, the table and the
   hook the rewritten code calls. The compile-time half rewrites [%break] and
   harvests the locals in scope at it, which needs the typed tree and so runs
   inside the typing pass, next to the autorun rewrite that works the same
   way. *)

(* The hook is injected into every session under this name, so the rewrite has
   something that typechecks. Only stdlib types cross the boundary: the
   session cannot see the worker's own modules, whose interfaces are not on
   its search path. *)
(* Two names, and only applications between them: no tuple and no list is
   built in generated code. Ast_helper.Exp.tuple changed shape between the
   compiler versions this supports, and the map says every compiler-libs
   signature the worker touches is identical across them. A sequence of
   applications keeps that true. *)
let hook_name = "__camlkit_break"
(* The site's id crosses into the hook: a name can be written in several
   places, and the site is what is counted, armed and reported. See
   docs/wayfinder/tickets/049. *)
let hook_type = "int -> unit"
let local_hook_name = "__camlkit_break_local"
let local_hook_type = "string -> string -> Obj.t -> unit"

(* name, printed type, value. The type is printed at compile time and re-typed
   when the value is bound, which is what decides whether a local can be
   handed back at all. *)
type local = { name : string; ty : string; value : Obj.t }

(* The site travels with the stop: a parked phrase is reported by the marker
   and the place it stopped at, and a parked id alone says which hit rather
   than which marker. *)
type _ Effect.t += Stop : int * local list -> unit Effect.t

(* Filled by the calls the rewrite puts before the stop, drained by it. A
   phrase is evaluated sequentially and a stop is reached at most once at a
   time, so one buffer is enough. *)
let pending : local list ref = ref []

(* --- the registry ------------------------------------------------------- *)

(* Every marker is named, and the name is what outlives the call: the marker
   compiles into the code holding it, so a site fires whenever that code runs
   and the server has nothing to delete. What it can do is disarm - a flag this
   table holds and the hook reads - which is the only way to stop a marker in a
   hot function short of redefining the function. See tickets/049. *)
type kind = Break | Watch

(* How many recorded values a watch keeps, per site and per call. A watch in a
   hot loop would otherwise be a leak with a printer attached: the table holds
   the values themselves, since printing needs the type and that is only known
   at typecheck time. A value physically equal to the one before it in a list
   is not stored again, which is incremental's cutoff idea and bounds an
   unchanging loop at one entry; an equal value freshly allocated each time is
   stored, and collapsed when printed instead (Watch.printed).
   ponytail: one fixed cap; make it per call if anyone needs more. *)
let trail_limit = 100

(* Newest first, with its length kept so that recording is not a walk. The
   list may run to twice the limit before it is cut back, which makes a
   recording O(1) amortised: cutting on every hit copied a full list each time,
   and a watch reached a million times allocated 5 GB doing it. Read it through
   [recent], never [items]. *)
type recent = { mutable items : Obj.t list; mutable len : int }

let empty () = { items = []; len = 0 }

let recent r = if r.len <= trail_limit then r.items
  else List.filteri (fun i _ -> i < trail_limit) r.items

(* Where a marker is written: the top-level definition holding it, its line in
   the call that sent it, and for a watch the watched expression's own text. A
   name may be written at several places, so this is how a caller tells them
   apart. *)
type at = { in_def : string option; line : int; code : string }

(* A name, which groups the places it is written: its hits are theirs, and
   arming or disarming it does all of them. It holds no arming of its own, so
   a site written later starts armed, and the warning that reports it says so. *)
type marker = {
  name : string;
  kind : kind;
  mutable hits : int;            (* lifetime, every site of the name *)
}

(* One place a marker is written. A name can be written at several; a watch's
   sites each keep their own type, so every value is printed with the type of
   the site that recorded it: one shared type per name printed an int as a
   string, and the worker died. A breakpoint's site is what a stop reports and
   what can be disarmed on its own. *)
type site = {
  id : int;
  site_name : string;
  site_kind : kind;
  at : at;
  mutable site_armed : bool;
  mutable site_hits : int;
  mutable call_hits : int;       (* since start_call, beside this_call *)
  (* A watch's values, newest first, as the runtime handed them over. Printing
     needs the type, which only the typing pass knows, so they are kept raw and
     printed when the result is built. [trail] is the site's lifetime and
     [this_call] is emptied at the start of every phrase. *)
  trail : recent;
  this_call : recent;
  mutable printed_as : (Types.type_expr * Env.t) option;
}

let markers : (string, marker) Hashtbl.t = Hashtbl.create 8
let sites : (int, site) Hashtbl.t = Hashtbl.create 8
let last_site = ref 0

(* The id the next site written will get. Sites are numbered when a call is
   typed but only registered once it runs, so a call that fails or is checked
   uses no numbers. *)
let next_site () = !last_site + 1

let find_marker name = Hashtbl.find_opt markers name

let register ~kind name =
  match Hashtbl.find_opt markers name with
  | Some m -> m
  | None ->
    let m = { name; kind; hits = 0 } in
    Hashtbl.replace markers name m; m

let add_site ~kind ~id ~name ~at ~printed_as =
  ignore (register ~kind name);
  last_site := max !last_site id;
  Hashtbl.replace sites id
    { id; site_name = name; site_kind = kind; at; site_armed = true;
      site_hits = 0; call_hits = 0; trail = empty (); this_call = empty (); printed_as }

let find_site id = Hashtbl.find_opt sites id

let known () =
  List.sort (fun a b -> compare a.name b.name)
    (Hashtbl.fold (fun _ m acc -> m :: acc) markers [])

let sites_of name =
  List.sort (fun a b -> compare a.id b.id)
    (Hashtbl.fold (fun _ s acc -> if s.site_name = name then s :: acc else acc)
       sites [])

let all_sites () =
  List.sort (fun a b -> compare a.id b.id)
    (Hashtbl.fold (fun _ s acc -> s :: acc) sites [])

let set_name ~armed name =
  match Hashtbl.find_opt markers name with
  | None -> false
  | Some _ ->
    List.iter (fun s -> s.site_armed <- armed) (sites_of name);
    true

let set_site ~armed id =
  match Hashtbl.find_opt sites id with
  | None -> false
  | Some s -> s.site_armed <- armed; true

(* Emptied per phrase, so a result reports what its own phrase recorded rather
   than everything the site has ever seen. The trail keeps the rest. *)
let start_call () =
  Hashtbl.iter
    (fun _ s -> s.this_call.items <- []; s.this_call.len <- 0; s.call_hits <- 0)
    sites

(* Called by the rewritten code, with the site it was written at. Counts every
   hit; stores a value only when it differs from the newest one in that list.
   Each list is compared against its own head rather than one shared last
   value, because this_call starts empty: a shared one made a call that
   repeated the previous call's final value report nothing. *)
let record id (v : Obj.t) =
  match Hashtbl.find_opt sites id with
  | None -> ()
  | Some s ->
    s.site_hits <- s.site_hits + 1;
    s.call_hits <- s.call_hits + 1;
    (match Hashtbl.find_opt markers s.site_name with
     | Some m -> m.hits <- m.hits + 1
     | None -> ());
    if s.site_armed then begin
      let add r =
        match r.items with
        | p :: _ when p == v -> ()
        | l ->
          r.items <- v :: l;
          r.len <- r.len + 1;
          if r.len >= 2 * trail_limit then begin
            r.items <- recent r;
            r.len <- trail_limit
          end
      in
      add s.trail;
      add s.this_call
    end

(* What a continue with abandon raises inside the parked phrase. The toplevel
   prints an exception by the name it was defined with, which for a worker
   module is dune's wrapped one, so the session defines its own and the worker
   raises that. This is the fallback if that ever fails. *)
exception Abandoned
let abandoned = ref Abandoned
let abandoned_name = "Camlkit_abandoned"
let abandoned_binding = "__camlkit_abandoned"

(* What running one phrase came to: it finished, or it performed [%break] and
   handed back the rest of itself. A resumed phrase can stop again, so the
   continuation returns a step of its own. *)
type step =
  | Ran of bool
  | Broke of int * local list * (unit, step) Effect.Deep.continuation

type parked = {
  id : int;
  site : int;
  k : (unit, step) Effect.Deep.continuation;
  locals : local list;
  (* The phrases of the same call that have not run yet, and the index of the
     one that stopped. A call is the unit of work: a stop suspends the call,
     not only the phrase, so resuming finishes what was sent rather than
     dropping the tail of it. They typechecked in the original call, and
     toplevel code resolves a global when it is compiled, so a redefinition
     made while parked cannot change what they refer to. *)
  rest : (Parsetree.toplevel_phrase * string option * string) list;
  index : int;
  (* The autorun rule the stopped phrase runs under, if any. Its run has not
     returned, so a later phrase under the same rule cannot start one, and
     fails with the scheduler's message rather than ours; see tickets/052. *)
  run : string option;
  (* The rest of the phrase prints into the buffer the original call gave
     execute_phrase, which is inside the continuation and cannot be swapped.
     They are held here so the call that resumes can read what was added. *)
  buf : Buffer.t;
  seen : int;                    (* bytes of buf already reported *)
}

let table : (int, parked) Hashtbl.t = Hashtbl.create 4
let last_id = ref 0

let fresh_id () = incr last_id; !last_id
let find id = Hashtbl.find_opt table id
let forget id = Hashtbl.remove table id
let park p = Hashtbl.replace table p.id p

(* The parked phrases stopped inside a run of this rule, oldest first. *)
let parked_in_run rule =
  List.sort (fun a b -> compare a.id b.id)
    (Hashtbl.fold (fun _ p acc -> if p.run = Some rule then p :: acc else acc)
       table [])

let ids () =
  List.sort compare (Hashtbl.fold (fun id _ acc -> id :: acc) table [])

(* The only id when there is exactly one, so the common case needs no id. *)
let the_only_one () = match ids () with [ id ] -> Some id | _ -> None

(* What the rewritten phrase calls. Injected as a value, so its type is the
   one declared above and nothing else of ours is reachable from a session. *)
let local_hook name ty value = pending := { name; ty; value } :: !pending

let hook id : unit =
  let locals = List.rev !pending in
  pending := [];
  match Hashtbl.find_opt sites id with
  | None -> ()
  | Some site ->
  site.site_hits <- site.site_hits + 1;
  (match Hashtbl.find_opt markers site.site_name with
   | Some m -> m.hits <- m.hits + 1
   | None -> ());
  (* A disarmed marker is still compiled into the code and still reached; it
     just does nothing, which is the whole of what disarming can mean when the
     call is in the caller's own function body. The locals are dropped with it,
     since nothing will read them. *)
  if not site.site_armed then ()
  else
  (* An effect cannot be performed in a frame the runtime entered: a signal
     handler, or a callback arriving from C. The raw Unhandled exception names
     this worker's internals and tells a caller nothing, so it is turned into
     a sentence here, at the only place that knows what was being attempted. *)
  try Effect.perform (Stop (id, locals))
  with Effect.Unhandled _ ->
    failwith
      "a breakpoint was reached in a frame the runtime entered, such as a \
       signal handler or a callback from C, where an effect cannot be \
       performed. The phrase failed instead of stopping. Put the breakpoint \
       in code the phrase itself calls."

(* --- the rewrite ------------------------------------------------------- *)

(* [%break "name"] is an extension point so that a stray one is a compile error
   we can explain, and so nothing a session defines can be mistaken for it. The
   name is required: it is the handle the markers tool disarms by, and a marker
   that cannot be named cannot be turned off without redefining the function
   holding it. See tickets/049. *)
let marker_name (e : Parsetree.expression) =
  match e.pexp_desc with
  | Parsetree.Pexp_extension
      ({ txt = "break"; _ },
       Parsetree.PStr
         [ { pstr_desc =
               Parsetree.Pstr_eval
                 ({ pexp_desc =
                      Parsetree.Pexp_constant
                        { pconst_desc = Parsetree.Pconst_string (name, _, _);
                          _ };
                    _ }, _);
             _ } ]) -> Some name
  | _ -> None

let is_marker e = marker_name e <> None

(* A break extension that is not [%break "name"]: one with no name, a name that
   is not a string literal, or one in structure-item position. The compiler
   calls it an uninterpreted extension, which is true and does not say what the
   right form is. *)
let malformed_marker str =
  let found = ref None in
  let note loc = if !found = None then found := Some loc in
  let iter =
    { Ast_iterator.default_iterator with
      expr = (fun self (e : Parsetree.expression) ->
          (match e.pexp_desc with
           | Parsetree.Pexp_extension ({ txt = "break"; _ }, _)
             when marker_name e = None -> note e.pexp_loc
           | _ -> ());
          Ast_iterator.default_iterator.expr self e);
      structure_item = (fun self (i : Parsetree.structure_item) ->
          (match i.pstr_desc with
           | Parsetree.Pstr_extension (({ txt = "break"; _ }, _), _) ->
             note i.pstr_loc
           | _ -> ());
          Ast_iterator.default_iterator.structure_item self i) }
  in
  iter.Ast_iterator.structure iter str;
  !found

let ghost loc = { loc with Location.loc_ghost = true }

let ident ~loc name =
  Ast_helper.Exp.ident ~loc { Location.txt = Longident.Lident name; loc }

(* First pass: every marker becomes a call with no locals. It typechecks, it
   runs if nothing rewrites it again, and its location is where the locals of
   the second pass come from. *)
(* Ldot is the one compiler-libs constructor that differs across the versions
   this supports, so the path is built the way the rest of the worker builds
   one. *)
let obj_repr = Option.get (Longident.unflatten [ "Obj"; "repr" ])

let unit_expr ~loc =
  Ast_helper.Exp.construct ~loc
    { Location.txt = Longident.Lident "()"; loc } None

let string_expr ~loc s =
  Ast_helper.Exp.constant ~loc (Ast_helper.Const.string s)

let int_expr ~loc i = Ast_helper.Exp.constant ~loc (Ast_helper.Const.int i)

let to_empty_call ~id (e : Parsetree.expression) =
  let loc = ghost e.pexp_loc in
  Ast_helper.Exp.apply ~loc (ident ~loc hook_name)
    [ (Asttypes.Nolabel, int_expr ~loc id) ]

(* Second pass: the same call, now carrying the locals harvested for it. The
   list is built here rather than in the worker because the values have to be
   read where they are in scope, which is only inside the phrase. *)
let to_call ~loc ~id locals =
  let loc = ghost loc in
  let str s = string_expr ~loc s in
  let announce (name, ty) =
    Ast_helper.Exp.apply ~loc (ident ~loc local_hook_name)
      [ (Asttypes.Nolabel, str name);
        (Asttypes.Nolabel, str ty);
        (Asttypes.Nolabel,
         Ast_helper.Exp.apply ~loc
           (Ast_helper.Exp.ident ~loc { Location.txt = obj_repr; loc })
           [ (Asttypes.Nolabel, ident ~loc name) ]) ]
  in
  List.fold_right
    (fun local rest -> Ast_helper.Exp.sequence ~loc (announce local) rest)
    locals
    (Ast_helper.Exp.apply ~loc (ident ~loc hook_name)
       [ (Asttypes.Nolabel, int_expr ~loc id) ])

(* Nothing is printed back to source: the tree is mapped and everything
   inserted carries a ghost location, so the caller's own text keeps its line
   and character numbers. Positions are what this project reports, in error
   spans and now in backtraces, and a rewrite that moved them would be a
   regression dressed as a feature. *)
let mapper ~replace =
  { Ast_mapper.default_mapper with
    expr = (fun self e ->
        match marker_name e with
        | Some name -> replace ~name e
        | None -> Ast_mapper.default_mapper.expr self e) }

let count_markers str =
  let n = ref 0 in
  let m = mapper ~replace:(fun ~name:_ e -> incr n; e) in
  ignore (m.Ast_mapper.structure m str);
  !n

let has_marker str = count_markers str > 0

(* The name a top-level definition binds, for saying where a site is: the
   first variable its first binding introduces. *)
let defines (item : Parsetree.structure_item) =
  match item.pstr_desc with
  | Parsetree.Pstr_value (_, vb :: _) ->
    let rec name (p : Parsetree.pattern) =
      match p.ppat_desc with
      | Parsetree.Ppat_var { txt; _ } -> Some txt
      | Parsetree.Ppat_constraint (p, _) | Parsetree.Ppat_alias (p, _) -> name p
      | _ -> None
    in
    name vb.Parsetree.pvb_pat
  | _ -> None

(* A piece of the caller's source on one line and cut short: enough to
   recognise, not a second copy of it. *)
let code_of ~src (loc : Location.t) =
  let a = loc.loc_start.Lexing.pos_cnum and b = loc.loc_end.Lexing.pos_cnum in
  if a < 0 || b > String.length src || b <= a then ""
  else
    let flat =
      String.concat " "
        (List.filter (( <> ) "")
           (String.split_on_char ' '
              (String.map (function '\n' | '\t' | '\r' -> ' ' | c -> c)
                 (String.sub src a (b - a)))))
    in
    if String.length flat <= 60 then flat else String.sub flat 0 57 ^ "..."

(* Maps each top-level item with a mapper built for it, so a replacement knows
   which definition it is in. *)
let per_item make str =
  List.map
    (fun item -> let m = make (defines item) in m.Ast_mapper.structure_item m item)
    str

(* First pass. Each marker is numbered from [first], in order, and comes back
   with its location - how the second pass finds what the first inserted: a
   typedtree constructor's arity differs across the compiler versions this
   supports, while a location does not - its name, its id and where it is
   written. *)
let rewrite_empty ~first str =
  let found = ref [] and next = ref first in
  let str =
    per_item
      (fun in_def ->
         mapper ~replace:(fun ~name e ->
             let id = !next in
             incr next;
             let at = { in_def; code = "";
                        line = e.Parsetree.pexp_loc.loc_start.Lexing.pos_lnum } in
             found := (e.Parsetree.pexp_loc, name, id, at) :: !found;
             to_empty_call ~id e))
      str
  in
  (str, List.rev !found)

(* Locals are taken in order of appearance, which is the order the markers are
   met in both trees, so the two passes line up without matching locations.
   The ids go with them, so the second tree calls the same sites. *)
let rewrite_with ids_and_locals str =
  let remaining = ref ids_and_locals in
  let m =
    mapper ~replace:(fun ~name:_ e ->
        match !remaining with
        | [] -> e
        | (id, locals) :: rest ->
          remaining := rest;
          to_call ~loc:e.pexp_loc ~id locals)
  in
  m.Ast_mapper.structure m str

(* --- harvesting the locals --------------------------------------------- *)

(* A value visible at the marker that was not visible before the phrase began
   is a local of the phrase. Comparing identities rather than names is what
   makes a local that shadows a session binding come out as the local. *)
let value_identities env =
  let seen = Hashtbl.create 64 in
  Env.fold_values
    (fun _ path _ () ->
       match path with
       | Path.Pident id -> Hashtbl.replace seen (Ident.unique_name id) ()
       | _ -> ())
    None env ();
  seen

let print_type ty =
  let b = Buffer.create 64 in
  let ppf = Format.formatter_of_buffer b in
  Printtyp.type_expr ppf ty;
  Format.pp_print_flush ppf ();
  Buffer.contents b

(* A local whose type still has a variable in it cannot be handed back: the
   declaration that binds it would generalise, so a later phrase could pick
   any type it liked for a value that already has one, and the toplevel would
   read it at that type. That segfaults, which is how this was found.

   A variable is a quote that does not follow an identifier character, so a
   type named t' is not mistaken for one. *)
let has_type_variable ty =
  let n = String.length ty in
  let rec go i =
    if i >= n then false
    else if ty.[i] <> '\'' then go (i + 1)
    else
      let previous = if i = 0 then ' ' else ty.[i - 1] in
      match previous with
      | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '\'' -> go (i + 1)
      | _ -> true
  in
  go 0

let is_bindable name =
  name <> "" && name.[0] <> '_'
  && (match name.[0] with 'a' .. 'z' -> true | _ -> false)

let same_place (a : Location.t) (b : Location.t) =
  a.loc_start.Lexing.pos_cnum = b.loc_start.Lexing.pos_cnum
  && a.loc_end.Lexing.pos_cnum = b.loc_end.Lexing.pos_cnum

(* The typing environment at each marker, one per location given, in the same
   order. The outermost node at a location is the inserted call itself, and an
   iterator meets it before its children, so the first match is the right
   one. *)
let marker_envs tstr locs =
  let found = Hashtbl.create 4 in
  let iter =
    { Tast_iterator.default_iterator with
      expr = (fun self (e : Typedtree.expression) ->
          List.iteri
            (fun i loc ->
               if (not (Hashtbl.mem found i)) && same_place loc e.exp_loc then
                 Hashtbl.replace found i e.exp_env)
            locs;
          Tast_iterator.default_iterator.expr self e) }
  in
  iter.Tast_iterator.structure iter tstr;
  List.mapi (fun i _ -> Hashtbl.find_opt found i) locs

let locals_at ~before env =
  let acc = ref [] in
  Env.fold_values
    (fun name path vd () ->
       match path with
       | Path.Pident id when is_bindable name
                          && not (Hashtbl.mem before (Ident.unique_name id)) ->
         acc := (name, print_type vd.Types.val_type) :: !acc
       | _ -> ())
    None env ();
  List.sort compare !acc
