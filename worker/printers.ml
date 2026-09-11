(* utop installs toplevel printers automatically for values marked
   [@@ocaml.toplevel_printer], which is how a library makes its abstract types
   print readably. That machinery is UTop_main.Autoprinter, an internal
   submodule, invoked from UTop_main.execute_phrase, which wraps
   Toploop.execute_phrase. We call Toploop directly, so it was simply absent:
   requiring a package and evaluating one of its values printed <abstr> where
   real utop printed the value.

   Two halves: printers arriving with a loaded cmi (a required package), and
   printers defined inside the session itself.

   The second half is deliberately not a copy of Autoprinter.scan_env. That
   walks Env summaries by matching every constructor, and already needs a cppo
   branch for 5.5, which is the churn we chose not to inherit. Env.fold_modules
   and Env.fold_values have stable signatures and say the same thing, so we
   fold and remember what we have already seen. *)

let is_auto_printer_attribute (attr : Parsetree.attribute) =
  match attr.attr_name.txt with
  | "toplevel_printer" | "ocaml.toplevel_printer" -> true
  | _ -> false

(* Longident.Ldot changed shape in OCaml 5.4, which is why utop preprocesses
   its own sources with cppo. UTop_compat.ldot papers over it for us. *)
let cons_path path id =
  let comp = Ident.name id in
  match path with
  | None -> Longident.Lident comp
  | Some path -> UTop_compat.ldot path comp

let rec walk_sig pp ~path signature =
  List.iter (walk_sig_item pp (Some path)) signature

and walk_sig_item pp path = function
  | Types.Sig_module (id, _, { Types.md_type = mty; _ }, _, _) ->
    walk_mty pp (cons_path path id) mty
  | Types.Sig_value (id, vd, _) ->
    if List.exists is_auto_printer_attribute vd.Types.val_attributes then
      (try Topdirs.dir_install_printer pp (cons_path path id)
       with _ -> ())   (* a printer we cannot install is not worth failing over *)
  | _ -> ()

and walk_mty pp path = function
  | Types.Mty_signature s -> walk_sig pp ~path s
  | _ -> ()

(* The hook fires as cmis are loaded, so scanning is deferred until a phrase
   runs, exactly as utop does it. *)
let pending = ref []

let () = UTop_compat.add_cmi_hook (fun cmi -> pending := cmi :: !pending)

let scan_cmis pp =
  let cmis = !pending in
  pending := [];
  List.iter
    (fun (cmi : Cmi_format.cmi_infos) ->
       walk_sig pp ~path:(Longident.Lident cmi.Cmi_format.cmi_name) cmi.Cmi_format.cmi_sign)
    cmis

(* Names already accounted for. Primed at startup so the first phrase does not
   walk the whole of the stdlib looking for an attribute it will never find. *)
let seen_modules : (string, unit) Hashtbl.t = Hashtbl.create 64
let seen_values : (string, unit) Hashtbl.t = Hashtbl.create 64

let fold_names () =
  let env = !Toploop.toplevel_env in
  let modules =
    Env.fold_modules (fun name _ decl acc -> (name, decl) :: acc) None env [] in
  let values =
    Env.fold_values (fun name _ vd acc -> (name, vd) :: acc) None env [] in
  (modules, values)

let prime () =
  let modules, values = fold_names () in
  List.iter (fun (name, _) -> Hashtbl.replace seen_modules name ()) modules;
  List.iter (fun (name, _) -> Hashtbl.replace seen_values name ()) values

let scan_env pp =
  let modules, values = fold_names () in
  List.iter
    (fun (name, (decl : Types.module_declaration)) ->
       if not (Hashtbl.mem seen_modules name) then begin
         Hashtbl.replace seen_modules name ();
         walk_mty pp (Longident.Lident name) decl.Types.md_type
       end)
    modules;
  List.iter
    (fun (name, (vd : Types.value_description)) ->
       if not (Hashtbl.mem seen_values name) then begin
         Hashtbl.replace seen_values name ();
         if List.exists is_auto_printer_attribute vd.Types.val_attributes then
           try Topdirs.dir_install_printer pp (Longident.Lident name) with _ -> ()
       end)
    values

let scan pp = scan_cmis pp; scan_env pp
