(* Loading a dune project's own libraries.

   dune's private libraries are not findlib packages, so `require` cannot see
   them. What works, and what a session otherwise has to hand-roll, is adding
   each library's compiled-interface directory to the search path and then
   loading its archive. dune hides the .cmi files under `.<lib>.objs/byte`,
   which is the part nobody guesses.

   Load order matters and we do not parse dune's metadata to learn it: we
   retry the failures until a pass makes no progress, which settles any
   dependency order in a few passes. *)

(* dune knows the answer already. `dune top` prints the exact directives a
   toplevel needs for a project: the .objs/byte directories, the external
   package directories, and the archives in dependency order, externals
   included. That subsumes the scan below, the retry-until-settled ordering,
   and the separate require step for things like sedlex. *)
let dune_binary = lazy (Wire.Exe.find "dune")

(* Only ask when the path is itself a project root. dune searches upwards for
   a dune-project, so pointing at a subdirectory would silently answer for the
   enclosing project, and running it inside another dune invocation contends
   for the build lock. *)
let is_dune_project path = Sys.file_exists (Filename.concat path "dune-project")

let dune_top path =
  if not (is_dune_project path) then []
  else
  let cmd =
    Printf.sprintf "cd %s && %s top . 2>/dev/null" (Filename.quote path)
      (Filename.quote (Lazy.force dune_binary)) in
  let ic = Unix.open_process_in cmd in
  let rec drain acc =
    match input_line ic with
    | line -> drain (line :: acc)
    | exception End_of_file -> List.rev acc
  in
  let lines = drain [] in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> lines
  | _ -> []

(* #directory "..." ;; and #load "..." ;; *)
let directive_arg prefix line =
  let line = String.trim line in
  let p = "#" ^ prefix ^ " \"" in
  if String.length line > String.length p
  && String.sub line 0 (String.length p) = p then
    match String.index_from_opt line (String.length p) '"' with
    | Some close ->
      Some (String.sub line (String.length p) (close - String.length p))
    | None -> None
  else None

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

let name_of archive = Filename.remove_extension (Filename.basename archive)

(* Archives the worker already contains.

   `dune top` names every external a project depends on, including the ones
   this worker is itself built from, and loading one again re-initialises
   modules the running toplevel is made of. Measured: loading the compiler-libs
   archives over the live Toploop leaves the worker dead on the next phrase,
   so a project that depends on compiler-libs could be loaded but not used.

   The list is the worker's own libraries, kept beside worker/dune. Archive
   names are not written out: findlib expands each package to its ancestors
   and reads their byte archives, so compiler-libs.toplevel brings ocamlcommon
   and ocamlbytecomp with it without anyone naming them.

   It has to follow worker/dune, and the test suite is what notices when it
   does not: when wire stopped depending on yojson, this list still claimed
   yojson was linked, so require of it became a no-op and a session could not
   use it. *)
let linked_packages =
  [ "compiler-libs.toplevel"; "findlib.top"; "unix"; "str" ]

let linked_archives = lazy (
  let packages =
    try Findlib.package_deep_ancestors [ "byte" ] linked_packages
    with _ -> linked_packages in
  List.concat_map
    (fun p ->
       match Findlib.package_property [ "byte" ] p "archive" with
       | exception _ -> []
       | archives ->
         String.split_on_char ' ' archives
         |> List.filter_map (fun a ->
             match String.trim a with "" -> None | a -> Some (name_of a)))
    packages)

(* Only an archive from outside the project: a project may well have a library
   of its own called str, and that one has to load. *)
let already_linked ~root archive =
  not (String.starts_with ~prefix:root archive)
  && List.mem (name_of archive) (Lazy.force linked_archives)

(* dune puts a library's .cmi files in .<name>.objs/byte beside its archive. *)
let interface_dirs archive =
  let dir = Filename.dirname archive in
  let name = Filename.remove_extension (Filename.basename archive) in
  List.filter Sys.file_exists
    [ dir; Filename.concat dir (Printf.sprintf ".%s.objs/byte" name) ]

let missing_unit err =
  let re = Str.regexp "undefined compilation unit `\\([A-Za-z0-9_]+\\)'" in
  try ignore (Str.search_forward re err 0); Some (Str.matched_group 1 err)
  with Not_found -> None

(* Which library provides a module. The failing unit is a module name, not a
   library name, so comparing it against archive names says "external" for a
   project's own modules. The modules live as .cmo files in the library's
   objs directory, so look there. *)
let provider ~archives unit_ =
  let wanted = String.lowercase_ascii unit_ ^ ".cmo" in
  List.find_map
    (fun a ->
       List.find_map
         (fun d ->
            match Sys.readdir d with
            | exception Sys_error _ -> None
            | entries ->
              if Array.exists
                  (fun e -> String.lowercase_ascii e = wanted) entries
              then Some (name_of a) else None)
         (interface_dirs a))
    archives

(* Topdirs writes the real diagnosis to its formatter and then raises something
   opaque: a bare Compenv.Exit_with_status 125 says nothing, while the
   formatter holds "The files ... disagree over interface Debug". Capture it. *)
let attempt ?(add_dirs = true) archive =
  let buf = Buffer.create 256 in
  let ppf = Format.formatter_of_buffer buf in
  if add_dirs then
    List.iter (fun d -> Topdirs.dir_directory d) (interface_dirs archive);
  let raised =
    try Topdirs.dir_load ppf archive; None
    (* Printexc gives "Symtable.Error(_)", which says nothing. The compiler's
       own reporter turns it into "Reference to undefined global ...". *)
    with e ->
      Some (try Toplevel.message_of_exn e with _ -> Printexc.to_string e) in
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

(* Ask dune, and fall back to scanning for a directory that is not a dune
   project (or a dune that cannot answer). *)
let load_via_dune ~libraries path =
  match dune_top path with
  | [] -> None
  | lines ->
    let dirs = List.filter_map (directive_arg "directory") lines in
    let archives = List.filter_map (directive_arg "load") lines in
    let archives =
      match libraries with
      | [] -> archives
      | wanted -> List.filter (fun a -> List.mem (name_of a) wanted) archives
    in
    let archives = List.filter (fun a -> not (already_linked ~root:path a)) archives in
    if archives = [] then None
    else begin
      List.iter (fun d -> Topdirs.dir_directory d) dirs;
      (* dune's order is already correct, so load once through, in order. *)
      let loaded, failed =
        List.fold_left
          (fun (loaded, failed) a ->
             match attempt ~add_dirs:false a with
             | Ok () -> (a :: loaded, failed)
             | Error e -> (loaded, (a, e) :: failed))
          ([], []) archives
      in
      Some (List.rev loaded, List.rev failed)
    end

let load ~libraries path =
  match load_via_dune ~libraries path with
  | Some (loaded, failed) ->
    Ok (List.map name_of loaded, List.map (fun (a, e) -> (name_of a, e)) failed)
  | None ->
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
      let name_of = name_of in
            let failed_names = List.map (fun (a, _) -> name_of a) failed in
      let annotate (archive, err) =
        let hint =
          match missing_unit err with
          | None -> ""
          | Some unit_ ->
            match provider ~archives:found unit_ with
            | Some lib when List.mem lib failed_names ->
              (* The common cascade: one library failed and everything that
                 depends on it reports the same shape of error. Saying
                 "external" here sent a reader chasing four phantom problems
                 instead of the one real one. *)
              Printf.sprintf
                "\n  %s comes from %s, which failed above. Fix that one first; \
                 this is a knock-on failure." unit_ lib
            | Some lib ->
              Printf.sprintf "\n  %s comes from %s, in this project." unit_ lib
            | None ->
              Printf.sprintf
                "\n  %s is not built by this project, so it comes from an \
                 external library. Load it with the require tool first, then \
                 load again." unit_
        in
        (archive, err ^ hint)
      in
      Ok (List.map name_of (List.rev loaded),
          List.map (fun (a, e) -> (name_of a, e)) (List.map annotate (List.rev failed)))
