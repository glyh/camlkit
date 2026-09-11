(* Loading a dune project's own libraries.

   dune's private libraries are not findlib packages, so `require` cannot see
   them. What works, and what a session otherwise has to hand-roll, is adding
   each library's compiled-interface directory to the search path and then
   loading its archive. dune hides the .cmi files under `.<lib>.objs/byte`,
   which is the part nobody guesses.

   Load order matters and we do not parse dune's metadata to learn it: we
   retry the failures until a pass makes no progress, which settles any
   dependency order in a few passes. *)

let rec walk acc dir =
  match Sys.readdir dir with
  | exception Sys_error _ -> acc
  | entries ->
    Array.fold_left
      (fun acc name ->
         let path = Filename.concat dir name in
         if Sys.is_directory path then walk acc path
         else if Filename.check_suffix name ".cma" then path :: acc
         else acc)
      acc entries

(* A dune build tree, given either the project root or a directory inside it. *)
let build_root path =
  let candidates =
    [ Filename.concat path "_build/default"; Filename.concat path "_build"; path ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some d -> Ok d
  | None -> Error (Printf.sprintf "no such directory: %s" path)

let archives ~libraries root =
  let all = walk [] root in
  match libraries with
  | [] -> all
  | wanted ->
    List.filter
      (fun p -> List.mem (Filename.remove_extension (Filename.basename p)) wanted)
      all

(* dune puts a library's .cmi files in .<name>.objs/byte beside its archive. *)
let interface_dirs archive =
  let dir = Filename.dirname archive in
  let name = Filename.remove_extension (Filename.basename archive) in
  List.filter Sys.file_exists
    [ dir; Filename.concat dir (Printf.sprintf ".%s.objs/byte" name) ]

(* Topdirs writes the real diagnosis to its formatter and then raises something
   opaque: a bare Compenv.Exit_with_status 125 says nothing, while the
   formatter holds "The files ... disagree over interface Debug". Capture it. *)
let attempt archive =
  let buf = Buffer.create 256 in
  let ppf = Format.formatter_of_buffer buf in
  List.iter (fun d -> Topdirs.dir_directory d) (interface_dirs archive);
  let raised =
    try Topdirs.dir_load ppf archive; None
    (* Printexc gives "Symtable.Error(_)", which says nothing. The compiler's
       own reporter turns it into "Reference to undefined global ...". *)
    with e ->
      Some (try String.trim (UTop.get_message Errors.report_error e)
            with _ -> Printexc.to_string e) in
  Format.pp_print_flush ppf ();
  let said = String.trim (Buffer.contents buf) in
  (* dir_load usually reports by printing rather than raising, so an empty
     formatter is the only reliable signal of success. When it does raise, the
     exception alone is useless (Compenv.Exit_with_status 125), so report both. *)
  match raised, said with
  | None, "" -> Ok ()
  | None, said -> Error said
  | Some e, "" -> Error e
  | Some e, said -> Error (said ^ " (" ^ e ^ ")")

let load ~libraries path =
  match build_root path with
  | Error e -> Error e
  | Ok root ->
    match archives ~libraries root with
    | [] ->
      Error (Printf.sprintf "no .cma archives under %s; has the project been \
                             built for bytecode?" root)
    | found ->
      let rec pass remaining loaded errors =
        let failed, loaded =
          List.fold_left
            (fun (failed, loaded) a ->
               match attempt a with
               | Ok () -> (failed, a :: loaded)
               | Error e -> ((a, e) :: failed, loaded))
            ([], loaded) remaining
        in
        if List.length failed < List.length remaining && failed <> [] then
          pass (List.map fst failed) loaded errors
        else (loaded, failed)
      in
      let loaded, failed = pass found [] [] in
      (* A unit this project does not build is an external dependency dune
         would have linked for us. Say so, because the compiler's hint suggests
         #load, which is the wrong answer here. *)
      let annotate (archive, err) =
        let external_hint =
          try
            let i = Str.search_forward
                (Str.regexp "undefined compilation unit `\\([A-Za-z0-9_]+\\)'") err 0 in
            ignore i;
            let unit_ = Str.matched_group 1 err in
            let built_here =
              List.exists
                (fun a ->
                   String.lowercase_ascii (Filename.remove_extension
                                             (Filename.basename a))
                   = String.lowercase_ascii unit_)
                found
            in
            if built_here then ""
            else
              Printf.sprintf
                "\n  %s is not built by this project, so it comes from an \
                 external library. Load it with the require tool first, then \
                 load again." unit_
          with Not_found -> ""
        in
        (archive, err ^ external_hint)
      in
      Ok (List.rev loaded, List.map annotate (List.rev failed))
