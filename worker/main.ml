(* The worker owns one toplevel and answers one request at a time.
   No Eio, no Lwt: it is sequential by nature, and staying free of an event
   loop keeps Lwt_main.run working inside evaluated code.

   There is no greeting. The server named the capture file on the command
   line, so it already knows everything a handshake could have told it, and a
   request simply waits in the pipe until the toplevel is ready to read it. *)

open Wire

(* If the server is killed outright, nothing it owns runs, and a worker that
   is mid-phrase is not reading its pipe either, so it neither sees EOF nor
   gets told to stop. It would spin forever.

   So watch for the parent going away. The alarm is armed only while a request
   is being handled, which is the only time this can happen and also avoids a
   signal interrupting the blocking read between requests. The handler runs
   during evaluation for the same reason the interrupt does: OCaml delivers
   signals at safepoints. *)
let watch_parent () =
  let parent = Unix.getppid () in
  Sys.set_signal Sys.sigalrm
    (Sys.Signal_handle
       (fun _ ->
          if Unix.getppid () <> parent then exit 0 else ignore (Unix.alarm 2)))

let watching () = ignore (Unix.alarm 2)
let not_watching () = ignore (Unix.alarm 0)

let usage () =
  prerr_endline "camlkit-worker: expects the capture file path as its only argument";
  exit 2

let () =
  (* Before anything shells out: a client spawns us from a shell without
     `opam env`, and dune cannot resolve a project's packages without it. *)
  Wire.Exe.adopt_switch ();
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
  watch_parent ();
  let rec loop () =
    match Frame_io.read ic with
    | None -> ()
    | Some { Frame.meta; _ } ->
      watching ();
      let response =
        match Msg.decode_request meta with
        | Msg.Eval { source; autorun } -> Eval.eval cap ~autorun source
        | Msg.Describe path -> Eval.describe cap path
        | Msg.Continue { id; abandon } -> Eval.continue_ cap ~id ~abandon
        | Msg.Inspect { id } -> Eval.inspect cap ~id
        | Msg.Require packages -> Eval.require cap packages
        | Msg.Load { path; libraries; packages } ->
          Eval.load cap ~libraries ~packages path
      in
      (* Cap the payload: a phrase can print without bound, and an MCP result
         is a single payload with no streaming. Spans are clamped to match, so
         an agent never reads past the end of what it was sent. *)
      (* Read at most the cap, and be told whether more existed, so the
         truncated flag reports what actually happened rather than only what
         the clamp did. *)
      let payload, _ = Capture.contents ~limit:Msg.output_limit cap in
      (* The reader stops at the same limit the clamp uses, so the clamp alone
         accounts for what was lost, per phrase and by how much. *)
      let clamp ps = fst (Msg.clamp ~limit:(String.length payload) ps) in
      let response =
        match response with
        | Msg.Completed c -> Msg.Completed { c with phrases = clamp c.phrases }
        | Msg.Interrupted r -> Msg.Interrupted { r with done_ = clamp r.done_ }
        | Msg.Stopped st -> Msg.Stopped { st with done_ = clamp st.done_ }
        | Msg.Failed f -> Msg.Failed { f with done_ = clamp f.done_ }
        | other -> other
      in
      Frame_io.write oc { Frame.meta = Msg.encode_response response; payload };
      not_watching ();
      loop ()
  in
  loop ()
