(* Merlin answers questions about source that a toplevel cannot: where a name
   is defined, its type at a position, what a file contains, where a name is
   used, and what has a given type.

   It is a separate process with a documented CLI, not a library: one JSON
   envelope per command, source on stdin. Deliberately not linked, because its
   internal libraries are far less stable than the CLI and that coupling is
   what has bitten repeatedly elsewhere in this project.

   Single mode rather than server. Server mode keeps a warm process and is
   faster - measured on a real project at 17 ms per query against 42 - but it
   leaves an ocamlmerlin-server behind per project, plus a `dune ocaml-merlin`
   helper, whose lifetime we neither own nor can reliably end. Single mode
   leaves nothing. Twenty-five milliseconds is not worth a process we cannot
   clean up, for a caller making a handful of queries rather than one per
   keystroke. *)

let binary = lazy (Wire.Exe.find "ocamlmerlin")

(* Every query runs merlin in the file's own directory, because that is how
   merlin finds a project's configuration. A relative path does not survive
   that `cd`: merlin is then asked about a filename that no longer resolves,
   and it answers without the project's configuration rather than refusing.
   `dump-configuration` came back with no `open_modules` at all, so `context`
   silently lost the wrapper - the one open a reader cannot guess. Commands
   that need only the source on stdin, `outline` among them, were unaffected,
   which is what kept this quiet.

   Resolved here rather than at the tool boundary so that the `cd`, the
   `-filename` and the source all refer to the same file however a caller
   spelled it. See docs/wayfinder/tickets/051. *)
let absolute path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
  else path

(* Project-wide occurrences need dune's index, and merlin says nothing when it
   is missing: it quietly answers from the current buffer alone and reports
   `class: return` with no notification. A caller then reads a complete-looking
   list that omits every use in every other file.

   So build the index first. It is cheap once the project itself is built -
   measured at 0.2 s - and correctness here is worth a build, because a wrong
   answer that looks complete is worse than a slow one. *)
(* Whether dune wrote any occurrence index under the build directory. Stops at
   the first one, so the answer on a project that has them costs a few
   directory reads; only a project with none pays for the whole walk.
   ponytail: a full walk in the negative case, narrow it if a large project
   ever notices. *)
let has_index build_dir =
  let rec look dir =
    match Sys.readdir dir with
    | exception Sys_error _ -> false
    | entries ->
      Array.exists
        (fun name ->
           let path = Filename.concat dir name in
           if Filename.check_suffix name ".ocaml-index" then true
           else Sys.is_directory path && look path)
        entries
  in
  look build_dir

let ensure_index file =
  match Wire.Exe.project_root_of (absolute file) with
  | None -> Error "not inside a dune project"
  | Some root ->
    let cmd =
      Printf.sprintf "cd %s && %s build @ocaml-index 2>&1"
        (Filename.quote root) (Filename.quote (Wire.Exe.find "dune"))
    in
    let ic = Unix.open_process_in cmd in
    let buf = Buffer.create 256 in
    (try
       while true do Buffer.add_channel buf ic 1 done
     with End_of_file -> ());
    (match Unix.close_process_in ic with
     | Unix.WEXITED 0 ->
       (* A zero exit is not an index. The occurrence data dune builds one from
          is written by the compiler, and only by OCaml 5.2 and later; these
          tools need no session, so they answer about whatever project they are
          pointed at, including one this server could never run a toplevel for.
          Such a project's index alias does not have to fail in order to
          produce nothing. Asking whether a file was written says so without
          having to know which of the reasons applied. *)
       if has_index (Filename.concat root "_build") then Ok ()
       else
         Error
           "dune built the index alias without error and wrote no index. The \
            occurrence data it is built from is written by OCaml 5.2 and \
            later, so a project on an older compiler has none"
     | _ -> Error (String.trim (Buffer.contents buf)))


let read_file path =
  let path = absolute path in
  match open_in_bin path with
  | ic ->
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic; Ok s
  | exception Sys_error e -> Error e

(* Merlin locates a project's configuration by walking up from the file, so it
   is run in the file's own directory. *)
let query ~command ~args ~file =
  let file = absolute file in
  match read_file file with
  | Error e -> Error e
  | Ok source ->
    let argv =
      [ Filename.quote (Lazy.force binary); "single"; command ]
      @ List.map Filename.quote args
      @ [ "-filename"; Filename.quote file; "2>/dev/null" ]
    in
    let cmd =
      Printf.sprintf "cd %s && %s"
        (Filename.quote (Filename.dirname file)) (String.concat " " argv)
    in
    let out, inp = Unix.open_process cmd in
    let answer =
      (* Writing source while merlin may already be answering: a closed pipe
         here is merlin having seen enough, not a failure. *)
      (try output_string inp source with Sys_error _ -> ());
      (try close_out inp with Sys_error _ -> ());
      let buf = Buffer.create 4096 in
      (try
         let chunk = Bytes.create 65536 in
         let rec go () =
           match input out chunk 0 (Bytes.length chunk) with
           | 0 -> ()
           | n -> Buffer.add_subbytes buf chunk 0 n; go ()
         in
         go ()
       with End_of_file -> ());
      Buffer.contents buf
    in
    ignore (Unix.close_process (out, inp));
    if String.trim answer = "" then
      Error
        (Printf.sprintf
           "ocamlmerlin produced no answer. It is a runtime dependency and \
            must be installed in the same opam switch as this server: try \
            `opam install --switch <switch> merlin`. Looked for %s."
           (Lazy.force binary))
    else
      match Yojson.Safe.from_string answer with
      | exception Yojson.Json_error e -> Error ("unparseable merlin reply: " ^ e)
      | json ->
        let open Yojson.Safe.Util in
        (* Every command answers with the same envelope; only value differs. *)
        match member "class" json |> to_string_option with
        | Some "return" -> Ok (member "value" json)
        | Some other ->
          Error (Printf.sprintf "merlin %s: %s" other
                   (Yojson.Safe.to_string (member "value" json)))
        | None -> Error "merlin reply had no class"

let position line col = Printf.sprintf "%d:%d" line col

(* What `document` answers with.

   Every outcome arrives as `class: return` carrying a plain string, so a name
   that is not in scope reads exactly like a docstring unless the sentinels are
   known. They are a closed set, spelled out in merlin's
   src/commands/query_json.ml, and this is the whole of it. Two are constant
   and are matched whole; the rest are built from a name and are matched by the
   part that is not. The one that cannot be recognised is `File_not_found`,
   whose message is arbitrary, so it is returned as documentation; it means an
   interface the name lives in is missing, which is an honest thing to show.

   A comment whose first line is one of these sentinels would be misread. That
   is not worth defending against. *)
let documentation value =
  match value with
  | `String s ->
    let starts p =
      String.length s >= String.length p
      && String.sub s 0 (String.length p) = p
    in
    let contains p =
      let re = Str.regexp_string p in
      try ignore (Str.search_forward re s 0); true with Not_found -> false
    in
    if s = "No documentation available" || s = "Not a valid identifier"
       || starts "Not in environment '" || starts "didn't manage to find "
       || contains " was supposed to be in "
       || contains "is a builtin, and it is therefore impossible"
    then Error s
    else Ok s
  | _ -> Error "merlin answered document with something other than text"

(* Merlin infers which namespace to search from the node under the cursor, even
   when the name is given outright: src/analysis/locate.ml infers a context
   from the browse tree and src/analysis/env_lookup.ml maps a module path to
   modules alone. So asking for a value at a position inside a module path
   answers "Not in environment", about a name that is plainly in scope.

   Column zero is never inside a module path, a constructor or a record label,
   which are the three narrow contexts, so the permissive one applies and every
   namespace is searched. The caller's position is therefore not used for a
   name it named itself; it gets this one. *)
let neutral_position = position 1 0
