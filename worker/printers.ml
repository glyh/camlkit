(* utop installs toplevel printers automatically for values marked
   [@@ocaml.toplevel_printer], which is how a library makes its abstract types
   print readably. That machinery is UTop_main.Autoprinter, an internal
   submodule, invoked from UTop_main.execute_phrase, which wraps
   Toploop.execute_phrase. We call Toploop directly, so it was simply absent:
   requiring a package and evaluating one of its values printed <abstr> where
   real utop printed the value.

   ponytail: only the cmi half is reimplemented, which covers packages brought
   in by require. Printers defined inside the session itself need Autoprinter's
   scan_env, which walks Env summaries and is the part most exposed to
   compiler-libs churn between releases. *)

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

let scan pp =
  let cmis = !pending in
  pending := [];
  List.iter
    (fun (cmi : Cmi_format.cmi_infos) ->
       walk_sig pp ~path:(Longident.Lident cmi.Cmi_format.cmi_name) cmi.Cmi_format.cmi_sign)
    cmis
