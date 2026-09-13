(* Swapping a function in a loaded project, so that every caller sees the
   replacement: callers in other modules, callers in its own module, and its
   own recursive calls. See docs/wayfinder/tickets/054.

   OCaml links a call inside a module directly, so overwriting the function in
   its module's block reaches callers in other modules only. The swap is made
   at build time instead: load builds the project through this file as a ppx,
   and every top-level function written with parameters checks a cell on entry,
   calling what the cell holds if something has been put there.

     let f ?(x = 1) (a, b) = body
   becomes
     let f ?x:p1 p2 =
       if Obj.is_block !cell then (Obj.obj !cell) ?x:p1 p2
       else match (match p1 with Some d -> d | None -> 1) with x ->
            match p2 with (a, b) -> body

   The original body stays where it was, so the function's type is inferred
   exactly as before, polymorphism included: the call through the cell has no
   type of its own and takes whatever the parameters and the body give it.

   The cells are exported as one array under a fixed name, which the ppx also
   appends to the interface, so a function the .mli hides still has a cell.
   The eval half, [%swap], finds the array through the module path and checks
   the replacement against the function's own type before storing it. *)

open Parsetree

let cells_name = "__camlkit_cells"

let ghost loc = { loc with Location.loc_ghost = true }

let parse_structure s = Parse.implementation (Lexing.from_string s)

let lident ~loc path =
  { Location.txt = Option.get (Longident.unflatten path); loc }

let ident ~loc path = Ast_helper.Exp.ident ~loc (lident ~loc path)

let var ~loc name = Ast_helper.Pat.var ~loc { Location.txt = name; loc }

(* The part of the rewrite that goes inside a function. [cell] names the unit's
   cell for it. None for an expression that is not written as a function: its
   arity and labels are not in the syntax, and wrapping it could change what it
   does. *)
let rewrite_function ~cell (e : expression) =
  match e.pexp_desc with
  | Pexp_function (params, constraint_, body) ->
    let loc = ghost e.pexp_loc in
    let fresh =
      let n = ref 0 in
      fun () -> incr n; Printf.sprintf "__camlkit_p%d" !n in
    (* Each value parameter becomes a plain variable, and what the original
       parameter did - its pattern, its default - is done on it in the body. *)
    let params, args, unwraps =
      List.fold_left
        (fun (params, args, unwraps) (p : function_param) ->
           match p.pparam_desc with
           | Pparam_newtype _ -> (p :: params, args, unwraps)
           | Pparam_val (label, default, pat) ->
             let v = fresh () in
             let arg = ident ~loc [ v ] in
             let scrutinee =
               match default with
               | None -> arg
               | Some d ->
                 Ast_helper.Exp.match_ ~loc arg
                   [ Ast_helper.Exp.case
                       (Parse.pattern (Lexing.from_string
                                         "Stdlib.Option.Some __camlkit_d"))
                       (ident ~loc [ "__camlkit_d" ]);
                     Ast_helper.Exp.case
                       (Parse.pattern (Lexing.from_string "Stdlib.Option.None"))
                       d ]
             in
             ({ p with pparam_desc = Pparam_val (label, None, var ~loc v) } :: params,
              (label, arg) :: args,
              (fun inner ->
                 Ast_helper.Exp.match_ ~loc scrutinee
                   [ Ast_helper.Exp.case pat inner ]) :: unwraps))
        ([], [], []) params
    in
    let params, args, inner =
      match body with
      | Pfunction_body b -> (params, args, b)
      | Pfunction_cases (cases, _, _) ->
        let v = fresh () in
        ({ pparam_desc = Pparam_val (Nolabel, None, var ~loc v); pparam_loc = loc }
         :: params,
         (Asttypes.Nolabel, ident ~loc [ v ]) :: args,
         Ast_helper.Exp.match_ ~loc (ident ~loc [ v ]) cases)
    in
    if args = [] then None else
    (* [unwraps] is last parameter first, so folding it wraps outwards and the
       first parameter's match ends up outermost, in the original order. *)
    let original = List.fold_left (fun inner u -> u inner) inner unwraps in
    let held = Ast_helper.Exp.apply ~loc (ident ~loc [ "Stdlib"; "!" ])
        [ (Nolabel, ident ~loc [ cell ]) ] in
    let swapped =
      Ast_helper.Exp.apply ~loc
        (Ast_helper.Exp.apply ~loc (ident ~loc [ "Stdlib"; "Obj"; "obj" ])
           [ (Nolabel, held) ])
        (List.rev args) in
    let test = Ast_helper.Exp.apply ~loc (ident ~loc [ "Stdlib"; "Obj"; "is_block" ])
        [ (Nolabel, held) ] in
    Some { e with
           pexp_desc =
             Pexp_function
               (List.rev params, constraint_,
                Pfunction_body
                  (Ast_helper.Exp.ifthenelse ~loc test swapped (Some original))) }
  | _ -> None

(* A tag for this unit's cell names. A module without an interface exports its
   cells, and an `include` of it would shadow a unit's own cells of the same
   name, so the names are specific to the file. *)
let unit_tag () =
  String.sub (Digest.to_hex (Digest.string !Location.input_name)) 0 8

(* The implementation half: cells first, the rewritten items, the array last,
   so no include can shadow it. Functions in submodules are keyed by their path
   inside the unit. A functor body is left alone: one cell would be shared by
   every application. *)
let rewrite_structure (str : structure) =
  let tag = unit_tag () in
  let cells = ref [] in
  let rec items prefix str = List.map (item prefix) str
  and item prefix (i : structure_item) =
    match i.pstr_desc with
    | Pstr_value (rf, vbs) ->
      let vb (b : value_binding) =
        match b.pvb_pat.ppat_desc with
        | Ppat_var { txt; _ } ->
          (* The cell is only taken once the function is known to be one. *)
          let cell = Printf.sprintf "__camlkit_swap_%s_%d" tag (List.length !cells) in
          (match rewrite_function ~cell b.pvb_expr with
           | Some e -> cells := (prefix ^ txt, cell) :: !cells; { b with pvb_expr = e }
           | None -> b)
        | _ -> b
      in
      { i with pstr_desc = Pstr_value (rf, List.map vb vbs) }
    | Pstr_module ({ pmb_name = { txt = Some name; _ }; _ } as mb) ->
      let rec body (m : module_expr) =
        match m.pmod_desc with
        | Pmod_structure s ->
          { m with pmod_desc = Pmod_structure (items (prefix ^ name ^ ".") s) }
        | Pmod_constraint (inner, mty) ->
          { m with pmod_desc = Pmod_constraint (body inner, mty) }
        | _ -> m
      in
      { i with pstr_desc = Pstr_module { mb with pmb_expr = body mb.pmb_expr } }
    | _ -> i
  in
  let str = items "" str in
  let cells = List.rev !cells in
  let decls =
    List.concat_map
      (fun (_, name) ->
         parse_structure
           (Printf.sprintf "let %s = Stdlib.ref (Stdlib.Obj.repr 0)" name))
      cells in
  let array =
    parse_structure
      (Printf.sprintf "let %s = [| %s |]" cells_name
         (String.concat "; "
            (List.map (fun (key, name) -> Printf.sprintf "(%S, %s)" key name) cells)))
  in
  decls @ str @ array

let cells_type = "(Stdlib.String.t * Stdlib.Obj.t Stdlib.ref) Stdlib.Array.t"

let rewrite_signature (sg : signature) =
  sg @ Parse.interface
    (Lexing.from_string (Printf.sprintf "val %s : %s" cells_name cells_type))

(* Run as `camlkit-worker --swap-ppx`, which is what load names in OCAMLPARAM. *)
let ppx_flag = "--swap-ppx"

(* A unit this worker is itself linked with is left as built. Loading any
   other build of it disagrees with the worker's copy over its interface, and
   a rewritten one always would, so rewriting it only turned a load that
   worked - camlkit loading its own source - into one that refused.
   The ppx sees a file, not a unit, so the unit's names are reconstructed the
   way dune forms them: the file's base name, or that name inside a wrapped
   library, which dune opens by its alias module (Wire, or Wire__ when the
   library has a main module of its own). *)
let linked_with_worker () =
  let base =
    let file = Filename.basename !Location.input_name in
    String.capitalize_ascii
      (match String.index_opt file '.' with
       | Some i -> String.sub file 0 i
       | None -> file) in
  let names =
    base :: List.map
      (fun m ->
         if String.ends_with ~suffix:"__" m then m ^ base else m ^ "__" ^ base)
      !Clflags.open_modules in
  let linked = List.map fst (Symtable.init_toplevel ()) in
  List.exists (fun n -> List.mem n linked) names

let run_ppx () =
  Ast_mapper.run_main (fun _ ->
      if linked_with_worker () then Ast_mapper.default_mapper
      else
        { Ast_mapper.default_mapper with
          structure = (fun _ s -> rewrite_structure s);
          signature = (fun _ s -> rewrite_signature s) })

(* The eval half.

   [%swap Shop.Pricing.tax_rate (fun r -> 0.25)] stores a replacement and
   [%swap Shop.Pricing.tax_rate] puts the original back. Both are expressions
   of type unit. Before anything is stored, the replacement is checked against
   the function's own type scheme, so it has to be at least as general: a
   replacement for 'a list -> int that only takes int list is refused. *)

let hook_name = "__camlkit_swap"
let hook_type = cells_type ^ " -> string -> Obj.t -> unit"

(* The last cell under the key, since a unit that defines a name twice exports
   the second definition. The key was checked to exist before the phrase
   typed. *)
let hook (cells : (string * Obj.t ref) array) key value =
  let rec go i =
    if i >= 0 then
      let k, cell = cells.(i) in
      if k = key then cell := value else go (i - 1)
  in
  go (Array.length cells - 1)

let marker (e : expression) =
  match e.pexp_desc with
  | Pexp_extension ({ txt = "swap"; _ }, payload) ->
    Some
      (match payload with
       | PStr [ { pstr_desc = Pstr_eval (p, _); _ } ] ->
         (match p.pexp_desc with
          | Pexp_ident lid -> Ok (lid, None)
          | Pexp_apply ({ pexp_desc = Pexp_ident lid; _ }, [ (Nolabel, r) ]) ->
            Ok (lid, Some r)
          | _ -> Error ())
       | _ -> Error ())
  | _ -> None

let fail ~loc fmt =
  Printf.ksprintf (fun s -> raise (Location.Error (Location.error ~loc s))) fmt

let find_value env lid =
  match Env.find_value_by_name lid env with
  | (path, _) -> Some path
  | exception Not_found -> None

(* The module holding the cells for a path, and the function's key inside it:
   the longest prefix of the path that has a cell array. Longest first, because
   a submodule that includes another unit carries that unit's cells, and those
   are the right ones for what the submodule exports. *)
let resolve env components =
  let n = List.length components in
  let rec try_prefix k =
    if k < 1 then None
    else
      let prefix = List.filteri (fun i _ -> i < k) components in
      let key = String.concat "." (List.filteri (fun i _ -> i >= k) components) in
      match find_value env (Option.get (Longident.unflatten (prefix @ [ cells_name ]))) with
      | Some path ->
        (match (Obj.obj (Toploop.eval_value_path env path)
                : (string * Obj.t ref) array) with
         | cells -> Some (prefix, key, Array.exists (fun (k, _) -> k = key) cells)
         | exception _ -> try_prefix (k - 1))
      | None -> try_prefix (k - 1)
  in
  try_prefix (n - 1)

let expand env (e : expression) (lid : Longident.t Location.loc) replacement =
  let loc = lid.loc in
  let written = String.concat "." (Longident.flatten lid.txt) in
  let components = Longident.flatten lid.txt in
  let bound = find_value env lid.txt <> None in
  match resolve env components with
  | (None | Some (_, _, false)) when not bound ->
    (* Typed as it stands, so the compiler's own unbound-value error, with its
       spelling hints, is what the caller reads. *)
    Ast_helper.Exp.apply ~loc:(ghost loc) (ident ~loc [ "Stdlib"; "ignore" ])
      [ (Nolabel, Ast_helper.Exp.ident ~loc lid) ]
  | None ->
    fail ~loc
      "%s cannot be swapped: it is not in code that load built. Only a dune \
       project's own libraries, loaded with load, are built so their functions \
       can be swapped; Stdlib, packages loaded with require, and definitions \
       made in the session are not." written
  | Some (_, key, false) ->
    fail ~loc
      "%s cannot be swapped: only top-level functions written with parameters \
       (let f x = ..., fun, function) are, and %s is not one. A value, a \
       function computed by an expression, an external, and anything inside a \
       functor are left as they were built." written key
  | Some (_, _, true) when not bound ->
    fail ~loc
      "%s cannot be swapped from here: its interface does not export it, so \
       there is no type to check a replacement against." written
  | Some (prefix, key, true) ->
    let gloc = ghost e.pexp_loc in
    let cells = ident ~loc:gloc (prefix @ [ cells_name ]) in
    let name = List.nth components (List.length components - 1) in
    let store value =
      Ast_helper.Exp.apply ~loc:gloc (ident ~loc:gloc [ hook_name ])
        [ (Nolabel, cells);
          (Nolabel, Ast_helper.Exp.constant ~loc:gloc (Ast_helper.Const.string key));
          (Nolabel, Ast_helper.Exp.apply ~loc:gloc
             (ident ~loc:gloc [ "Stdlib"; "Obj"; "repr" ]) [ (Nolabel, value) ]) ]
    in
    let expr =
      match replacement with
      | None -> store (Ast_helper.Exp.constant ~loc:gloc (Ast_helper.Const.int 0))
      | Some r ->
        (* module M : module type of struct let f = <original> end =
             struct let f = <replacement> end
           Inclusion of one in the other is the check, so the error reads as
           the compiler's own signature mismatch, located at the replacement. *)
        let m = "Camlkit_swap" in
        let binding value =
          Ast_helper.Mod.structure ~loc:gloc
            [ Ast_helper.Str.value ~loc:gloc Nonrecursive
                [ Ast_helper.Vb.mk ~loc:gloc (var ~loc:gloc name) value ] ] in
        let expected =
          Ast_helper.Mty.typeof_ ~loc:gloc
            (binding (Ast_helper.Exp.ident ~loc lid)) in
        Ast_helper.Exp.letmodule ~loc:gloc { Location.txt = Some m; loc = gloc }
          (Ast_helper.Mod.constraint_ ~loc:gloc (binding r) expected)
          (store (ident ~loc:gloc [ m; name ]))
    in
    { expr with pexp_loc = e.pexp_loc }

let has_marker str =
  let found = ref false in
  let iter =
    { Ast_iterator.default_iterator with
      expr = (fun self e ->
          if marker e <> None then found := true;
          Ast_iterator.default_iterator.expr self e) } in
  iter.Ast_iterator.structure iter str;
  !found

(* Raises Location.Error for a swap that cannot be made, which the typecheck
   pass reports like any other error at that span. *)
let rewrite env str =
  if not (has_marker str) then str
  else
    let m =
      { Ast_mapper.default_mapper with
        expr = (fun self e ->
            match marker e with
            | Some (Ok (lid, replacement)) ->
              expand env e lid (Option.map (self.Ast_mapper.expr self) replacement)
            | Some (Error ()) ->
              fail ~loc:e.pexp_loc
                "A swap is written [%%swap Module.f replacement], or \
                 [%%swap Module.f] to put the original back: a path to the \
                 function, then optionally the expression to call instead."
            | None -> Ast_mapper.default_mapper.expr self e) }
    in
    m.Ast_mapper.structure m str
