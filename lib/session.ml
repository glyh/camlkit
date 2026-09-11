(* Imperative shell around Supervision: owns the process and the descriptors,
   and performs whatever the transition function asks for. *)

open Wire

type t = {
  name : string;
  pid : int;
  ic : in_channel;
  oc : out_channel;
  capture_path : string;   (* named by us, so partial output is readable *)
  mutable state : Supervision.state;
}

(* Installed, the worker sits beside the server as utop-mcp-worker, which is
   why worker/dune gives it that public_name. In a dune build tree the layout
   differs, so we also look where dune puts it; otherwise `dune exec utop-mcp`
   fails in a way that looks like a missing install.
   UTOP_MCP_WORKER overrides both. *)
let worker_path () =
  match Sys.getenv_opt "UTOP_MCP_WORKER" with
  | Some p -> p
  | None ->
    let dir = Filename.dirname Sys.executable_name in
    let installed = Filename.concat dir "utop-mcp-worker" in
    let in_build_tree =
      Filename.concat (Filename.dirname dir) "worker/main.bc.exe" in
    if Sys.file_exists installed then installed
    else if Sys.file_exists in_build_tree then in_build_tree
    else installed

let perform t = function
  | Supervision.Nothing -> ()
  | Supervision.Interrupt ->
    (try Unix.kill t.pid Sys.sigint with Unix.Unix_error _ -> ())
  | Supervision.Reap _ ->
    (try Unix.kill t.pid Sys.sigkill with Unix.Unix_error _ -> ());
    (try ignore (Unix.waitpid [] t.pid) with Unix.Unix_error _ -> ())

let apply t event =
  let state, action = Supervision.step t.state event in
  t.state <- state;
  perform t action

let spawn name =
  let exe = worker_path () in
  (* cloexec, emphatically. create_process dup2s the three descriptors it is
     given onto 0, 1 and 2 in the child, and dup2 clears the flag on the copy,
     so the worker still gets its pipes. Without cloexec it would also inherit
     the *other* ends: the write end of its own input pipe and the read end of
     its output pipe. It would then never see EOF when the server died, and
     neither would anyone reading its output. That leaves workers spinning
     forever after the server is gone. *)
  let to_worker_r, to_worker_w = Unix.pipe ~cloexec:true () in
  let from_worker_r, from_worker_w = Unix.pipe ~cloexec:true () in
  (* We choose the capture path rather than being told it, so the server can
     read partial output even from a worker that never answers. *)
  let capture_path = Filename.temp_file "utop-mcp-" ".out" in
  let pid =
    Unix.create_process exe [| exe; capture_path |]
      to_worker_r from_worker_w Unix.stderr
  in
  Unix.close to_worker_r;
  Unix.close from_worker_w;
  { name; pid; capture_path;
    ic = Unix.in_channel_of_descr from_worker_r;
    oc = Unix.out_channel_of_descr to_worker_w;
    state = Supervision.Idle }

let fd t = Unix.descr_of_in_channel t.ic
let state t = t.state
let is_busy t = Supervision.is_busy t.state
let deadline t = Supervision.deadline t.state

(* Whatever the current evaluation has printed so far. Readable at any time,
   including from a worker that is wedged, and after one has been killed,
   which is the reason the capture lives in a file the server named. *)
let partial_output t =
  match open_in_bin t.capture_path with
  | ic ->
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic; s
  | exception Sys_error _ -> ""

let send t request ~timeout =
  match Supervision.may_send t.state with
  | Error _ as e -> e
  | Ok () ->
    Frame_io.write t.oc { Frame.meta = Msg.json_of_request request; payload = "" };
    apply t (Supervision.Sent { now = Unix.gettimeofday (); timeout });
    Ok ()

let receive t =
  match Frame_io.read t.ic with
  | None | (exception Frame_io.Truncated) ->
    apply t (Supervision.Vanished "worker exited mid-request");
    Error "the worker died during evaluation; session state is gone"
  | Some { Frame.meta; payload } ->
    apply t Supervision.Replied;
    Ok (Msg.response_of_json meta, payload)

let on_deadline t ~grace =
  apply t (Supervision.Expired { now = Unix.gettimeofday (); grace })

let kill t why = apply t (Supervision.Vanished why)

(* The capture file outlives the worker by design, so removing it is ours. *)
let dispose t =
  kill t "session disposed";
  try Sys.remove t.capture_path with Sys_error _ -> ()
