(* utop's -emacs line protocol: every line is "command:argument". *)

type line = { cmd : string; arg : string }

let parse s =
  match String.index_opt s ':' with
  | None -> None
  | Some i ->
    Some { cmd = String.sub s 0 i;
           arg = String.sub s (i + 1) (String.length s - i - 1) }

(* A phrase is sent as input:<flags> then one data: line per input line, then end:. *)
let encode_input ?(flags = []) phrase =
  let data = String.split_on_char '\n' phrase |> List.map (fun l -> "data:" ^ l) in
  (Printf.sprintf "input:%s" (String.concat "," flags) :: data) @ [ "end:" ]

(* utop's stdout reader thread is scheduled independently of the command thread,
   so eval output arrives *after* the following prompt: with no reliable in-band
   end marker. We append a phrase that prints a unique marker; everything before
   it on stdout belongs to the user's phrase.
   The marker is random, not sequential: it is ordinary text with no protocol
   privilege, so a phrase that printed a predictable marker would truncate its
   own output silently.
   ponytail: costs one extra round trip per eval; only worth replacing if utop
   ever grows a real end-of-output signal. *)
let rng = lazy (Random.State.make_self_init ())

let fresh_token () =
  let r = Lazy.force rng in
  Printf.sprintf "%08x%08x" (Random.State.bits r) (Random.State.bits r)

let sentinel_marker token = "@@utop-mcp:" ^ token ^ "@@"
let sentinel_phrase token =
  Printf.sprintf "let () = Stdlib.print_endline %S;;" (sentinel_marker token)

(* utop announces its terminator as phrase-terminator:;; and will answer
   continue: for anything not ending in it. *)
let terminate ~terminator phrase =
  let t = String.trim phrase in
  if Filename.check_suffix t terminator then t else t ^ terminator

(* Spawn hermetically so a session does not inherit the developer's
   ~/.config/utop/init.ml or autoload dir, and via opam exec because an MCP
   client launches us with a minimal environment in which utop is usually not
   on PATH. opam exec execve's, so the child pid is utop itself and signals
   reach the toplevel directly. *)
let spawn_argv =
  [ "opam"; "exec"; "--"; "utop"; "-emacs";
    "-init"; "/dev/null"; "-no-autoload"; "-implicit-bindings" ]
