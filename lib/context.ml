(* The opens that put a session in a file's context.

   Both of the Lisp REPLs evaluate inside a namespace, so a fragment lifted
   out of a file resolves the way the file does. OCaml has no such thing, and
   `load` only makes a project's modules reachable: a session evaluating code
   copied out of lib/merlin.ml sees none of that file's opens and is not
   inside Merlin. The agent then guesses at qualifications it has no way to
   know. See docs/wayfinder/tickets/036.

   This answers with the preamble rather than applying it, because an open is
   ordinary session state: evaluated once, it holds for every later call, so
   there is nothing for eval to carry per call. It also keeps eval's spans
   honest, which prepending to the caller's source would not. *)

(* dune passes -open for a wrapped library, and that is the one a reader
   cannot guess. merlin already knows it: its configuration carries the same
   flags, so it is asked rather than derived from the project layout. *)
let wrappers ~file =
  match Merlin.query ~command:"dump-configuration" ~args:[] ~file with
  | Error e -> Error e
  | Ok value ->
    let open Yojson.Safe.Util in
    match member "ocaml" value |> member "open_modules" with
    | `List l -> Ok (List.filter_map to_string_option l)
    | _ -> Ok []

(* ponytail: the file's own opens are scanned, not parsed. A toplevel open is
   written at column zero and a nested one is indented, which is the whole
   heuristic; `open struct` does not match because a module path starts with a
   capital. Parse it properly if a file ever fools this. *)
let own_opens source =
  let re = Str.regexp "^open!?[ \t]+\\([A-Z][A-Za-z0-9_'.]*\\)" in
  let rec scan acc pos =
    match Str.search_forward re source pos with
    | exception Not_found -> List.rev acc
    | at -> scan (Str.matched_group 1 source :: acc) (at + 1)
  in
  scan [] 0

let module_of file =
  String.capitalize_ascii (Filename.remove_extension (Filename.basename file))

(* Order follows the real file: the wrapper is on the command line, the file's
   own opens come next, and the file's own module goes last because a name it
   defines shadows anything opened above it.

   The file's own module is only reachable when there is a wrapper. Without
   one the file is an executable's module or an unwrapped library's, which a
   session cannot name, so it is left out rather than offered and failing. *)
let of_file ~file =
  match Merlin.read_file file with
  | Error e -> Error e
  | Ok source ->
    match wrappers ~file with
    | Error e -> Error e
    | Ok wrappers ->
      let self = module_of file in
      let own =
        match wrappers with
        | [] -> []
        | w :: _ when w = self -> []   (* the file is the wrapper itself *)
        | w :: _ -> [ w ^ "." ^ self ]
      in
      Ok (wrappers @ own_opens source @ own)

let code opens =
  String.concat "" (List.map (fun m -> Printf.sprintf "open %s;;\n" m) opens)
