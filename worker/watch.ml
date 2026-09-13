(* A site that records every value flowing through it and never stops, which is
   sly's sticker and Pharo's watch behaviour. Against a breakpoint it is the
   complement: a stop shows the locals once, a watch reads a loop body a
   thousand times and parks nothing.

   Deliberately not the same rewrite. [%break "n"] replaces an expression in
   unit position and types as unit; [%watch "n" e] has to wrap e and give its
   value back, so it types as e does. What the two share is the registry, the
   naming and the location-matching walk over the typed tree - which is fifteen
   lines, not an abstraction. See docs/wayfinder/tickets/049.

   The value is kept raw and printed when the result is built, because printing
   needs the type and only the typing pass knows it. That is the locals
   harvest's trick without its temporary bindings. *)

let hook_name = "__camlkit_watch"
let hook_type = "int -> Obj.t -> unit"

(* The binding the wrapper puts the value in, so the expression is evaluated
   once rather than twice. Reserved, like the hooks. *)
let held = "__camlkit_watched"

let hook = Breakpoint.record

(* [%watch "name" expr]. The payload parses as an application of a string
   literal to the expression, which is what the caller writes and what reads
   naturally: [%watch "doubled" (x * 2)]. *)
let marker (e : Parsetree.expression) =
  match e.pexp_desc with
  | Parsetree.Pexp_extension
      ({ txt = "watch"; _ },
       Parsetree.PStr
         [ { pstr_desc =
               Parsetree.Pstr_eval
                 ({ pexp_desc =
                      Parsetree.Pexp_apply
                        ({ pexp_desc =
                             Parsetree.Pexp_constant
                               { pconst_desc =
                                   Parsetree.Pconst_string (name, _, _); _ };
                           _ },
                         [ (Asttypes.Nolabel, inner) ]);
                    _ }, _);
             _ } ]) -> Some (name, inner)
  | _ -> None

(* A watch extension that is not [%watch "name" expr]: no name, a name that is
   not a string literal, no expression, or one in structure-item position. *)
let malformed str =
  let found = ref None in
  let note loc = if !found = None then found := Some loc in
  let iter =
    { Ast_iterator.default_iterator with
      expr = (fun self (e : Parsetree.expression) ->
          (match e.pexp_desc with
           | Parsetree.Pexp_extension ({ txt = "watch"; _ }, _)
             when marker e = None -> note e.pexp_loc
           | _ -> ());
          Ast_iterator.default_iterator.expr self e);
      structure_item = (fun self (i : Parsetree.structure_item) ->
          (match i.pstr_desc with
           | Parsetree.Pstr_extension (({ txt = "watch"; _ }, _), _) ->
             note i.pstr_loc
           | _ -> ());
          Ast_iterator.default_iterator.structure_item self i) }
  in
  iter.Ast_iterator.structure iter str;
  !found

let ghost loc = { loc with Location.loc_ghost = true }

let ident ~loc name =
  Ast_helper.Exp.ident ~loc { Location.txt = Longident.Lident name; loc }

let obj_repr = Option.get (Longident.unflatten [ "Obj"; "repr" ])

(* let __camlkit_watched = e in hook <site id> (Obj.repr __camlkit_watched);
   __camlkit_watched

   The whole thing keeps the marker's own location, so the typed node found
   there has the watched expression's type: a let-in types as its body, and the
   body is the value. Everything inserted is ghost, so the caller's text keeps
   its line and character numbers, which error spans and backtraces report. *)
let wrap ~id (e : Parsetree.expression) inner =
  let loc = ghost e.pexp_loc in
  let held_pat = Ast_helper.Pat.var ~loc { Location.txt = held; loc } in
  let held_ref = ident ~loc held in
  let announce =
    Ast_helper.Exp.apply ~loc (ident ~loc hook_name)
      [ (Asttypes.Nolabel,
         Ast_helper.Exp.constant ~loc (Ast_helper.Const.int id));
        (Asttypes.Nolabel,
         Ast_helper.Exp.apply ~loc
           (Ast_helper.Exp.ident ~loc { Location.txt = obj_repr; loc })
           [ (Asttypes.Nolabel, held_ref) ]) ]
  in
  { (Ast_helper.Exp.let_ ~loc Asttypes.Nonrecursive
       [ Ast_helper.Vb.mk ~loc held_pat inner ]
       (Ast_helper.Exp.sequence ~loc announce held_ref))
    with Parsetree.pexp_loc = e.pexp_loc }

let mapper ~replace =
  { Ast_mapper.default_mapper with
    expr = (fun self e ->
        match marker e with
        | Some (name, inner) ->
          replace ~name e (Ast_mapper.default_mapper.expr self inner)
        | None -> Ast_mapper.default_mapper.expr self e) }

let count str =
  let n = ref 0 in
  let m = mapper ~replace:(fun ~name:_ e _ -> incr n; e) in
  ignore (m.Ast_mapper.structure m str);
  !n

let has_marker str = count str > 0

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

(* The watched expression as the caller wrote it, on one line and cut short:
   enough to recognise, not a second copy of the source. *)
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

(* The rewritten tree, and each site: where its typed node will be found, its
   name, the id it is numbered with from [first], and where it is written. *)
let rewrite ~src ~first str =
  let found = ref [] in
  let next = ref first in
  let rewrite_item item =
    let in_def = defines item in
    let m =
      mapper ~replace:(fun ~name e inner ->
          let id = !next in
          incr next;
          let at = { Breakpoint.in_def;
                     line = e.Parsetree.pexp_loc.loc_start.Lexing.pos_lnum;
                     code = (match marker e with
                         | Some (_, i) -> code_of ~src i.Parsetree.pexp_loc
                         | None -> "") } in
          found := (e.Parsetree.pexp_loc, name, id, at) :: !found;
          wrap ~id e inner)
    in
    m.Ast_mapper.structure_item m item
  in
  let str = List.map rewrite_item str in
  (str, List.rev !found)

(* The type and environment at each site, taken from the typed tree the same
   way a breakpoint's environment is, so the values it records can be printed
   once the phrase is over. Returned rather than stashed on the site: a call
   that fails to type, or is only checked, must leave the registry as it was,
   so eval stashes them once the call is going to run. *)
let types tstr sites =
  let want = List.map (fun (loc, _, _, _) -> loc) sites in
  let found = Hashtbl.create 4 in
  let iter =
    { Tast_iterator.default_iterator with
      expr = (fun self (e : Typedtree.expression) ->
          List.iteri
            (fun i loc ->
               if (not (Hashtbl.mem found i))
               && Breakpoint.same_place loc e.exp_loc then
                 Hashtbl.replace found i (e.Typedtree.exp_type,
                                          e.Typedtree.exp_env))
            want;
          Tast_iterator.default_iterator.expr self e) }
  in
  iter.Tast_iterator.structure iter tstr;
  List.mapi (fun i site -> (site, Hashtbl.find_opt found i)) sites

(* What a site recorded, printed, oldest first. The values are raw and the type
   is the one stashed above, so this is Toploop's own printer rather than a
   second rendering path. A site whose type was never stashed - the phrase
   failed to type, say - reports its count and no values rather than guessing.
   A run of equal printings is one entry: the record-time cutoff only sees
   physical equality, so a loop recomputing the same string would otherwise
   print it once per iteration. The hit count still says how many there were. *)
let printed (s : Breakpoint.site) values =
  match s.Breakpoint.printed_as with
  | None -> []
  | Some (ty, env) ->
    List.fold_left
      (fun acc v ->
         let buf = Buffer.create 64 in
         let ppf = Format.formatter_of_buffer buf in
         (try Toploop.print_value env v ppf ty
          with _ -> Buffer.add_string buf "<could not be printed>");
         Format.pp_print_flush ppf ();
         match acc, Buffer.contents buf with
         | prev :: _, p when prev = p -> acc
         | _, p -> p :: acc)
      [] values
