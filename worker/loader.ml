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

(* Three answers, not two. An empty list used to mean all of them, and the
   caller could only read it as "not a dune project", which is the one case
   where scanning the build tree is the right response. A dune project whose
   dune could not answer was scanned too, and that produced a confident wrong
   result rather than a failure: see docs/wayfinder/tickets/040. *)
type asked =
  | Not_a_project             (* no dune-project here; nothing to ask *)
  | Dune_failed of string     (* asked, and dune could not answer *)
  | Answered of string list

let dune_top ?(dir = ".") path =
  if not (is_dune_project path) then Not_a_project
  else
  (* stderr kept rather than discarded: it is the whole diagnosis when this
     fails, and it was being thrown away at the one point that had it. On the
     way through it is harmless, since only #directory and #load lines are
     read out of the output. *)
  let cmd =
    Printf.sprintf "cd %s && %s top %s 2>&1" (Filename.quote path)
      (Filename.quote (Lazy.force dune_binary)) (Filename.quote dir) in
  let ic = Unix.open_process_in cmd in
  let rec drain acc =
    match input_line ic with
    | line -> drain (line :: acc)
    | exception End_of_file -> List.rev acc
  in
  let lines = drain [] in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> Answered lines
  | _ ->
    let said = String.trim (String.concat "\n" lines) in
    Dune_failed (if said = "" then "dune exited non-zero and said nothing" else said)

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

(* A bytecode archive carries the compiler's magic in its first bytes, and the
   toplevel refuses one from another compiler with "is not a bytecode object
   file" - a sentence that names neither version and reads as a corrupt file
   rather than the wrong switch. Worse, it arrives once per archive, so a
   project of thirty libraries reports it thirty times with no cause in any of
   them.

   The worker is bytecode, so it can only ever load archives its own compiler
   produced. One archive decides the tree, since a build tree is built by one
   compiler. See docs/wayfinder/tickets/044. *)
let magic_of archive =
  let want = String.length Config.cma_magic_number in
  match open_in_bin archive with
  | exception Sys_error _ -> None
  | ic ->
    let got =
      match really_input_string ic want with
      | s -> Some s
      | exception End_of_file -> None
    in
    close_in_noerr ic; got

(* The message when the first archive was built by another compiler, and None
   when it was not - which includes an archive too short or unreadable to say,
   since that is a broken file and [attempt] reports it better than a guess
   about switches would. *)
let foreign_build archives =
  match archives with
  | [] -> None
  | first :: _ ->
    match magic_of first with
    | Some m when m <> Config.cma_magic_number ->
      Some
        (Printf.sprintf
           "%s was built by a different OCaml than this worker, so nothing \
            under it can be loaded. This worker is bytecode from OCaml %s, and \
            bytecode only loads archives its own compiler produced. Rebuild \
            the project in that switch, or point CAMLKIT_WORKER at a worker \
            built in the project's."
           first Config.version)
    | _ -> None

(* What the dune route concluded. [Scan] is the one case that falls through to
   walking the build tree: a directory that is not a dune project, where there
   is nothing to ask and nothing but archives to look at. Every other outcome
   is dune's answer, including dune failing to give one. *)
type route =
  | Scan
  | Refuse of string
  | Nothing_to_do
  | Did of (string list * (string * string) list)

(* The source directory an archive in the build tree was built from:
   <root>/_build/<context>/<dir>/<name>.cma gives <dir>. *)
let source_dir archive =
  let d = Filename.dirname archive in
  match Str.search_forward (Str.regexp "/_build/[^/]+/?") d 0 with
  | exception Not_found -> None
  | _ -> Some (match Str.string_after d (Str.match_end ()) with "" -> "." | r -> r)

(* The archives the wanted libraries need, in an order that loads. Picking the
   wanted names out of the whole project's list dropped what they depend on,
   so load of one library failed on an undefined unit from its dependency.
   dune top of a directory answers with that directory's libraries and their
   whole closure, so ask per directory and keep the first of each archive.
   ponytail: a directory holding several libraries loads all of them; filter
   by dune describe's requires if that ever matters. *)
let closure path wanted archives =
  let mine = List.filter (fun a -> List.mem (name_of a) wanted) archives in
  List.fold_left
    (fun acc a ->
       match acc, source_dir a with
       | Error _, _ -> acc
       | Ok got, None -> Ok (if List.mem a got then got else got @ [ a ])
       | Ok got, Some dir ->
         match dune_top ~dir path with
         | Answered lines ->
           Ok (got @ List.filter (fun a -> not (List.mem a got))
                       (List.filter_map (directive_arg "load") lines))
         | Dune_failed said -> Error said
         | Not_a_project -> Ok got)
    (Ok []) mine

let load_via_dune ~libraries path =
  match dune_top path with
  | Not_a_project -> Scan
  | Dune_failed said ->
    (* Deliberately not a scan. The scan answers from whatever .cma files are
       under _build, which for a real project means the externals it depends on
       are missing and anything else built - a test fixture, say - is present.
       That reads as a complete answer and is not one, and the error it then
       reports names a package the project does in fact declare. An honest
       failure names the one thing that fixes it. *)
    Refuse
      (Printf.sprintf
         "dune could not say what %s is built from, so there is nothing \
          reliable to load. Scanning the build tree instead would find the \
          wrong set: the externals this project depends on are not under \
          _build, and whatever else was built there is. dune said:\n%s"
         path said)
  | Answered lines ->
    let dirs = List.filter_map (directive_arg "directory") lines in
    let archives = List.filter_map (directive_arg "load") lines in
    let wanted_missing =
      match libraries with
      | [] -> []
      | wanted ->
        List.filter (fun w -> not (List.exists (fun a -> name_of a = w) archives))
          wanted
    in
    match wanted_missing with
    (* dune answered and does not have them, which the scan used to turn into
       "no .cma archives under ...", a sentence about the wrong thing. *)
    | _ :: _ ->
      Refuse
        (Printf.sprintf "%s does not build %s. It builds: %s"
           path (String.concat ", " wanted_missing)
           (match List.map name_of (List.filter_map (directive_arg "load") lines) with
            | [] -> "nothing"
            | names -> String.concat ", " names))
    | [] ->
    match (match libraries with
           | [] -> Ok archives
           | wanted -> closure path wanted archives) with
    | Error said ->
      Refuse (Printf.sprintf "dune could not say what %s needs:\n%s"
                (String.concat ", " libraries) said)
    | Ok archives ->
    let archives = List.filter (fun a -> not (already_linked ~root:path a)) archives in
    if archives = [] then Nothing_to_do
    else
    match foreign_build archives with
    | Some why -> Refuse why
    | None ->
    begin
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
      Did (List.map name_of (List.rev loaded),
           List.map (fun (a, e) -> (name_of a, e)) (List.rev failed))
    end

let load ~libraries path =
  match load_via_dune ~libraries path with
  | Did (loaded, failed) -> Ok (loaded, failed)
  | Refuse why -> Error why
  (* dune answered and every archive it named is already in the session. Not a
     failure and not a reason to scan: there is simply nothing left to load. *)
  | Nothing_to_do -> Ok ([], [])
  | Scan ->
  match build_root path with
  | Error e -> Error e
  | Ok root ->
    match archives ~libraries root with
    | [] ->
      Error (Printf.sprintf "no .cma archives under %s; has the project been \
                             built for bytecode?" root)
    | found when foreign_build found <> None ->
      Error (Option.get (foreign_build found))
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
