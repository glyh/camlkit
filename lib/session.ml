(* One session owns one worker process. The session never blocks on its own:
   it exposes the descriptor the server selects on, so a slow phrase in one
   session cannot stall another. *)

open Wire

type state =
  | Idle
  | Busy of { deadline : float; signalled : bool }
  | Dead of string

type t = {
  name : string;
  pid : int;
  ic : in_channel;
  oc : out_channel;
  mutable state : state;
}

(* The worker is installed beside the server. An override exists because a
   development tree is laid out differently from an install. *)
let worker_path () =
  match Sys.getenv_opt "UTOP_MCP_WORKER" with
  | Some p -> p
  | None -> Filename.concat (Filename.dirname Sys.executable_name) "utop-mcp-worker"

let spawn name =
  let exe = worker_path () in
  let to_worker_r, to_worker_w = Unix.pipe ~cloexec:false () in
  let from_worker_r, from_worker_w = Unix.pipe ~cloexec:false () in
  let pid =
    Unix.create_process exe [| exe |] to_worker_r from_worker_w Unix.stderr
  in
  Unix.close to_worker_r;
  Unix.close from_worker_w;
  let t = { name; pid;
            ic = Unix.in_channel_of_descr from_worker_r;
            oc = Unix.out_channel_of_descr to_worker_w;
            state = Idle } in
  (* The worker greets us once it has a toplevel ready. *)
  (match Frame.read t.ic with
   | Some _ -> ()
   | None -> t.state <- Dead "worker exited before greeting");
  t

let fd t = Unix.descr_of_in_channel t.ic

let is_busy t = match t.state with Busy _ -> true | _ -> false

(* Concurrent evals on one session are refused rather than queued: a toplevel
   is strictly sequential, and a queued call would spend its deadline waiting,
   which the caller cannot tell from a hang. *)
let send t request ~timeout =
  match t.state with
  | Dead why -> Error ("session is dead: " ^ why)
  | Busy _ -> Error "session is busy with another evaluation"
  | Idle ->
    Frame.write t.oc { Frame.meta = Msg.json_of_request request; payload = "" };
    t.state <- Busy { deadline = Unix.gettimeofday () +. timeout; signalled = false };
    Ok ()

let receive t =
  match Frame.read t.ic with
  | None | (exception Frame.Truncated) ->
    t.state <- Dead "worker exited mid-request";
    Error "the worker died during evaluation; session state is gone"
  | Some { Frame.meta; payload } ->
    t.state <- Idle;
    Ok (Msg.response_of_json meta, payload)

let kill t why =
  (try Unix.kill t.pid Sys.sigkill with Unix.Unix_error _ -> ());
  (try ignore (Unix.waitpid [] t.pid) with Unix.Unix_error _ -> ());
  t.state <- Dead why

(* Escalation: interrupt first, since a SIGINT leaves the toplevel usable and
   its bindings intact; only kill if the worker does not answer the signal.
   A phrase that swallows Sys.Break never returns, which is what the kill is
   for. *)
let on_deadline t ~grace =
  match t.state with
  | Busy { signalled = false; _ } ->
    (try Unix.kill t.pid Sys.sigint with Unix.Unix_error _ -> ());
    t.state <- Busy { deadline = Unix.gettimeofday () +. grace; signalled = true }
  | Busy { signalled = true; _ } ->
    kill t "did not respond to interrupt before the grace period expired"
  | Idle | Dead _ -> ()

let deadline t = match t.state with Busy { deadline; _ } -> Some deadline | _ -> None
