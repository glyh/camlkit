(* The worker owns one toplevel and answers one request at a time.
   No Eio, no Lwt: it is sequential by nature, and staying free of an event
   loop keeps Lwt_main.run working inside evaluated code.

   There is no greeting. The server named the capture file on the command
   line, so it already knows everything a handshake could have told it, and a
   request simply waits in the pipe until the toplevel is ready to read it. *)

open Wire

let usage () =
  prerr_endline "utop-mcp-worker: expects the capture file path as its only argument";
  exit 2

let () =
  let capture_path = if Array.length Sys.argv = 2 then Sys.argv.(1) else usage () in
  (* Move the inherited pipes out of the way before anything else, so the
     capture redirection cannot clobber them and evaluated code cannot reach
     the IPC channel through a standard descriptor. Unix.create_process only
     passes fds 0-2, so this rearrangement is how we get a private channel. *)
  let ic = Unix.in_channel_of_descr (Unix.dup Unix.stdin) in
  let oc = Unix.out_channel_of_descr (Unix.dup Unix.stdout) in
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  Unix.dup2 devnull Unix.stdin;
  let cap = Capture.create capture_path in
  Eval.init ();
  let rec loop () =
    match Frame_io.read ic with
    | None -> ()
    | Some { Frame.meta; _ } ->
      let response =
        match Msg.request_of_json meta with
        | Msg.Eval src -> Eval.eval cap src
        | Msg.Describe path -> Eval.describe cap path
        | Msg.Require packages -> Eval.require cap packages
      in
      Frame_io.write oc
        { Frame.meta = Msg.json_of_response response; payload = Capture.contents cap };
      loop ()
  in
  loop ()
