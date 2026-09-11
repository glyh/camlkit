(* The worker owns one toplevel and answers one request at a time.
   No Eio, no Lwt: it is sequential by nature, and staying free of an event
   loop keeps Lwt_main.run working inside evaluated code. *)

open Wire

let () =
  (* Move the inherited pipes out of the way before anything else, so the
     capture redirection cannot clobber them and evaluated code cannot reach
     the IPC channel through a standard descriptor. Unix.create_process only
     passes fds 0-2, so this rearrangement is how we get a private channel. *)
  let ic = Unix.in_channel_of_descr (Unix.dup Unix.stdin) in
  let oc = Unix.out_channel_of_descr (Unix.dup Unix.stdout) in
  let devnull = Unix.openfile "/dev/null" [ Unix.O_RDONLY ] 0 in
  Unix.dup2 devnull Unix.stdin;
  let cap = Capture.create () in
  Eval.init ();
  Frame.write oc { Frame.meta = `Assoc [ "hello", `String "utop-mcp-worker" ];
                   payload = "" };
  let rec loop () =
    match Frame.read ic with
    | None -> ()
    | Some { Frame.meta; _ } ->
      let response =
        match Msg.request_of_json meta with
        | Msg.Eval src -> Eval.eval cap src
        | Msg.Describe path -> Eval.describe cap path
        | Msg.Require packages -> Eval.require cap packages
      in
      Frame.write oc
        { Frame.meta = Msg.json_of_response response; payload = Capture.contents cap };
      loop ()
  in
  loop ()
