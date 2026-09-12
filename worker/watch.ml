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
let hook_type = "string -> Obj.t -> unit"

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

(* let __camlkit_watched = e in hook "name" (Obj.repr __camlkit_watched);
   __camlkit_watched

   The whole thing keeps the marker's own location, so the typed node found
   there has the watched expression's type: a let-in types as its body, and the
   body is the value. Everything inserted is ghost, so the caller's text keeps
   its line and character numbers, which error spans and backtraces report. *)
let wrap ~name (e : Parsetree.expression) inner =
  let loc = ghost e.pexp_loc in
  let held_pat = Ast_helper.Pat.var ~loc { Location.txt = held; loc } in
  let held_ref = ident ~loc held in
  let announce =
    Ast_helper.Exp.apply ~loc (ident ~loc hook_name)
      [ (Asttypes.Nolabel,
         Ast_helper.Exp.constant ~loc (Ast_helper.Const.string name));
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

(* The rewritten tree, and each site's name with the location its typed node
   will be found at. *)
let rewrite str =
  let found = ref [] in
  let m =
    mapper ~replace:(fun ~name e inner ->
        found := (e.Parsetree.pexp_loc, name) :: !found;
        wrap ~name e inner)
  in
  let str = m.Ast_mapper.structure m str in
  (str, List.rev !found)

(* The type and environment at each site, taken from the typed tree the same
   way a breakpoint's environment is, and stashed on the site so the values it
   records can be printed once the phrase is over. *)
let stash_types tstr sites =
  let want = List.map fst sites in
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
  List.iteri
    (fun i (_, name) ->
       match Hashtbl.find_opt found i with
       | None -> ()
       | Some ty ->
         let s = Breakpoint.register ~kind:Breakpoint.Watch name in
         s.Breakpoint.printed_as <- Some ty)
    sites

(* What a site recorded, printed. The values are raw and the type is the one
   stashed above, so this is Toploop's own printer rather than a second
   rendering path. A site whose type was never stashed - the phrase failed to
   type, say - reports its count and no values rather than guessing. *)
let printed (s : Breakpoint.site) values =
  match s.Breakpoint.printed_as with
  | None -> []
  | Some (ty, env) ->
    List.rev_map
      (fun v ->
         let buf = Buffer.create 64 in
         let ppf = Format.formatter_of_buffer buf in
         (try Toploop.print_value env v ppf ty
          with _ -> Buffer.add_string buf "<could not be printed>");
         Format.pp_print_flush ppf ();
         Buffer.contents buf)
      values
