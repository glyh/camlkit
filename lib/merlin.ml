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
(* [source] answers about text that is not on disk: merlin is told the file's
   name, so it still finds the project's configuration, and handed the edit to
   typecheck instead of what the file holds. Everything else here already sent
   the file's contents down the same pipe, so this only changes where they come
   from. See docs/wayfinder/tickets/042. *)
let query ?source ~command ~args ~file () =
  let file = absolute file in
  match (match source with Some s -> Ok s | None -> read_file file) with
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

(* What `expand-ppx` answers with.

   Two shapes under one class. On success an object with the generated `code`
   and the span of the deriver or extension node it came from; on failure a
   bare string, `class: return` and all, the same sentinel-inside-a-success
   that [documentation] above has to decode. There is one failure string and it
   is matched whole rather than by prefix, because unlike the document
   sentinels it carries nothing variable.

   See docs/wayfinder/tickets/037. *)
let expansion value =
  match value with
  | `String _ ->
    Error
      "no ppx deriver or extension node at that position. A deriver is the \
       name inside [@@deriving ...] and an extension is the [%name] itself; \
       the position has to be on one of those, not on the type or expression \
       it is attached to."
  | `Assoc _ as v ->
    (match Yojson.Safe.Util.member "code" v with
     | `String code -> Ok (code, Yojson.Safe.Util.member "deriver" v)
     | _ -> Error "merlin answered expand-ppx without any expanded code")
  | _ -> Error "merlin answered expand-ppx with neither code nor a reason"

(* Errors and warnings for one file, split apart.

   merlin answers with one list and a `type` on each entry - "typer",
   "parser", "env" and so on, with "warning" among them. A caller wants the two
   apart, the way an eval result keeps warnings out of its errors rather than
   interleaving them, so the split happens here rather than in the caller's
   head. `sub` carries nested messages and is usually empty; it is passed
   through when it is not. See docs/wayfinder/tickets/042. *)
let diagnostics value =
  match value with
  | `List items ->
    let kind item = Yojson.Safe.Util.member "type" item in
    let is_warning item = kind item = `String "warning" in
    let trim item =
      (* `valid` is true on everything merlin returns here, and the kind is
         already said by which list an entry is in. *)
      match item with
      | `Assoc fields ->
        `Assoc (List.filter
                  (fun (k, v) ->
                     match k, v with
                     | ("valid" | "type"), _ -> false
                     | "sub", `List [] -> false
                     | _ -> true)
                  fields)
      | other -> other
    in
    Ok (List.map trim (List.filter (fun i -> not (is_warning i)) items),
        List.map trim (List.filter is_warning items))
  | _ -> Error "merlin answered errors with something other than a list"

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

(* Fields merlin sends on every entry that say nothing: an outline item's empty
   `children` and `deprecated: false`, an occurrence's `stale: false`, an
   enclosing's `tail: "no"`, and any null, such as a search result's `doc` on
   a value with no comment. A search result's `constructible` goes too: it is
   the name and one `_` per argument, which its type already says. Absent is
   what an eval result means by nothing to say, and an outline of a large file
   paid for them once per definition. The
   other values of each are kept, since they are the case worth reading.

   `selection` stays: it is the name's span inside the item's, and an item
   starts at its `let`, so it is the position `uses` or `locate` on the name
   needs. See docs/wayfinder/tickets/053. *)
let rec trim = function
  | `Assoc fields ->
    `Assoc
      (List.filter_map
         (fun (k, v) ->
            match k, v with
            | "children", `List [] | "deprecated", `Bool false
            | "stale", `Bool false | "tail", `String "no"
            | _, `Null | "constructible", _ -> None
            | _ -> Some (k, trim v))
         fields)
  | `List items -> `List (List.map trim items)
  | other -> other
