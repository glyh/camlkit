(* Merlin answers questions about source that a toplevel cannot: where a name
   is defined, its type at a position, what a file contains, where a name is
   used, and what has a given type.

   It is a separate process with a documented CLI, not a library: one JSON
   envelope per command, source on stdin. Deliberately not linked, because its
   internal libraries are far less stable than the CLI and that coupling is
   what has bitten repeatedly elsewhere in this project.

   Server mode rather than single: identical arguments, about 2 ms per query
   against 30, because the process stays warm. *)

(* Beside our own executable before PATH, for the same reason dune is: we are
   installed into an opam switch where merlin lives, and a client may spawn us
   with neither on PATH. *)
let binary =
  lazy
    (let beside =
       Filename.concat (Filename.dirname Sys.executable_name) "ocamlmerlin" in
     if Sys.file_exists beside then beside else "ocamlmerlin")

let read_file path =
  match open_in_bin path with
  | ic ->
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic; Ok s
  | exception Sys_error e -> Error e

(* Merlin locates a project's configuration by walking up from the file, so it
   is run in the file's own directory. *)
let query ~command ~args ~file =
  match read_file file with
  | Error e -> Error e
  | Ok source ->
    let argv =
      [ Filename.quote (Lazy.force binary); "server"; command ]
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
