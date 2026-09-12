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
let hook_type = "unit -> unit"
let local_hook_name = "__camlkit_break_local"
let local_hook_type = "string -> string -> Obj.t -> unit"

(* name, printed type, value. The type is printed at compile time and re-typed
   when the value is bound, which is what decides whether a local can be
   handed back at all. *)
type local = { name : string; ty : string; value : Obj.t }

type _ Effect.t += Stop : local list -> unit Effect.t

(* Filled by the calls the rewrite puts before the stop, drained by it. A
   phrase is evaluated sequentially and a stop is reached at most once at a
   time, so one buffer is enough. *)
let pending : local list ref = ref []

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
  | Broke of local list * (unit, step) Effect.Deep.continuation

type parked = {
  id : int;
  k : (unit, step) Effect.Deep.continuation;
  locals : local list;
  (* The rest of the phrase prints into the buffers the original call gave
     execute_phrase, which is inside the continuation and cannot be swapped.
     They are held here so the call that resumes can read what was added. *)
  buf : Buffer.t;
  wbuf : Buffer.t;
  seen : int;                    (* bytes of buf already reported *)
}

let table : (int, parked) Hashtbl.t = Hashtbl.create 4
let last_id = ref 0

let fresh_id () = incr last_id; !last_id
let find id = Hashtbl.find_opt table id
let forget id = Hashtbl.remove table id
let park p = Hashtbl.replace table p.id p

let ids () =
  List.sort compare (Hashtbl.fold (fun id _ acc -> id :: acc) table [])

(* The only id when there is exactly one, so the common case needs no id. *)
let the_only_one () = match ids () with [ id ] -> Some id | _ -> None

(* What the rewritten phrase calls. Injected as a value, so its type is the
   one declared above and nothing else of ours is reachable from a session. *)
let local_hook name ty value = pending := { name; ty; value } :: !pending

let hook () : unit =
  let locals = List.rev !pending in
  pending := [];
  Effect.perform (Stop locals)

(* --- the rewrite ------------------------------------------------------- *)

(* [%break] is an extension point so that a stray one is a compile error we
   can explain, and so nothing a session defines can be mistaken for it. *)
let is_marker (e : Parsetree.expression) =
  match e.pexp_desc with
  | Parsetree.Pexp_extension ({ txt = "break"; _ }, Parsetree.PStr []) -> true
  | _ -> false

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

let to_empty_call (e : Parsetree.expression) =
  let loc = ghost e.pexp_loc in
  Ast_helper.Exp.apply ~loc (ident ~loc hook_name)
    [ (Asttypes.Nolabel, unit_expr ~loc) ]

(* Second pass: the same call, now carrying the locals harvested for it. The
   list is built here rather than in the worker because the values have to be
   read where they are in scope, which is only inside the phrase. *)
let to_call ~loc locals =
  let loc = ghost loc in
  let str s = Ast_helper.Exp.constant ~loc (Ast_helper.Const.string s) in
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
       [ (Asttypes.Nolabel, unit_expr ~loc) ])

(* Nothing is printed back to source: the tree is mapped and everything
   inserted carries a ghost location, so the caller's own text keeps its line
   and character numbers. Positions are what this project reports, in error
   spans and now in backtraces, and a rewrite that moved them would be a
   regression dressed as a feature. *)
let mapper ~replace =
  { Ast_mapper.default_mapper with
    expr = (fun self e ->
        if is_marker e then replace e
        else Ast_mapper.default_mapper.expr self e) }

let count_markers str =
  let n = ref 0 in
  let m = mapper ~replace:(fun e -> incr n; e) in
  ignore (m.Ast_mapper.structure m str);
  !n

let has_marker str = count_markers str > 0

(* The marker locations, in order, alongside the rewritten tree. They are how
   the second pass finds what the first pass inserted: a typedtree
   constructor's arity differs across the compiler versions this supports,
   while a location does not. *)
let rewrite_empty str =
  let locs = ref [] in
  let m =
    mapper ~replace:(fun e -> locs := e.Parsetree.pexp_loc :: !locs;
                      to_empty_call e)
  in
  let str = m.Ast_mapper.structure m str in
  (str, List.rev !locs)

(* Locals are taken in order of appearance, which is the order the markers are
   met in both trees, so the two passes line up without matching locations. *)
let rewrite_with locals_per_marker str =
  let remaining = ref locals_per_marker in
  let m =
    mapper ~replace:(fun e ->
        match !remaining with
        | [] -> to_empty_call e
        | locals :: rest -> remaining := rest; to_call ~loc:e.pexp_loc locals)
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
