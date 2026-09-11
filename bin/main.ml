(* The server is an I/O multiplexer, so Unix.select covers it: no Eio, no Lwt,
   no threads. It wakes on whichever comes first - a request on stdin, a
   worker's answer, or the earliest pending deadline - which keeps it
   responsive while one session is stuck.

   Nothing here may print to stdout: that descriptor is the MCP channel.
   Diagnostics go to stderr. *)

open Utop_mcp
open Wire

let eval_timeout = 30.0
let grace = 2.0

let sessions : (string, Session.t) Hashtbl.t = Hashtbl.create 8

(* JSON-RPC ids waiting on a worker, keyed by session name, with a note to
   attach to the reply. A session holds at most one, because a second
   evaluation is refused rather than queued. *)
let pending : (string, Jsonrpc.Id.t * string option) Hashtbl.t = Hashtbl.create 8

(* Names whose session died. The name stays usable, but the first result after
   the restart says so, since the new toplevel is empty. *)
let restarted : (string, string) Hashtbl.t = Hashtbl.create 8

let log fmt = Printf.ksprintf (fun s -> prerr_endline ("utop-mcp: " ^ s)) fmt

let reply id (r : Render.t) =
  Mcp.respond stdout
    (Jsonrpc.Packet.Response
       (Jsonrpc.Response.ok id (Mcp.tool_result ~structured:r.Render.structured
                                  ~is_error:r.Render.is_error
                                  [ Mcp.text r.Render.content ])))

let reply_error id (e : Jsonrpc.Response.Error.t) =
  Mcp.respond stdout (Jsonrpc.Packet.Response (Jsonrpc.Response.error id e))

(* --- tool calls --------------------------------------------------------- *)

let arg_string args name =
  match Yojson.Safe.Util.member name args with
  | `String s -> Ok s
  | `Null -> Error (Printf.sprintf "missing required argument %S" name)
  | _ -> Error (Printf.sprintf "argument %S must be a string" name)

let arg_strings args name =
  match Yojson.Safe.Util.member name args with
  | `List items ->
    (try Ok (List.map Yojson.Safe.Util.to_string items)
     with _ -> Error (Printf.sprintf "argument %S must be a list of strings" name))
  | `Null -> Error (Printf.sprintf "missing required argument %S" name)
  | _ -> Error (Printf.sprintf "argument %S must be a list of strings" name)

let request_of_call name args =
  match name with
  | "eval" -> Result.map (fun c -> Msg.Eval c) (arg_string args "code")
  | "describe" -> Result.map (fun p -> Msg.Describe p) (arg_string args "path")
  | "require" -> Result.map (fun p -> Msg.Require p) (arg_strings args "packages")
  | "reset" -> assert false                      (* handled before we get here *)
  | other -> Error (Printf.sprintf "no such tool: %s" other)

(* A session is created on first use. A name whose session died is reusable,
   because a name is only a handle and refusing it forever would make an agent
   invent new ones after every crash. The replacement toplevel is empty, so the
   first result after a restart carries a note saying so. *)
let session_for name =
  match Hashtbl.find_opt sessions name with
  | Some s -> Ok (s, None)
  | None ->
    match Session.spawn name with
    | s ->
      Hashtbl.replace sessions name s;
      let note = match Hashtbl.find_opt restarted name with
        | None -> None
        | Some why ->
          Hashtbl.remove restarted name;
          Some (Printf.sprintf
                  "Session %S was restarted (%s). This is a fresh toplevel: \
                   earlier bindings and loaded packages are gone." name why)
      in
      Ok (s, note)
    | exception Unix.Unix_error (e, _, _) ->
      Error (Printf.sprintf "could not start a worker: %s" (Unix.error_message e))

let discard name why =
  (match Hashtbl.find_opt sessions name with
   | Some s -> Session.kill s why; Hashtbl.remove sessions name
   | None -> ());
  Hashtbl.replace restarted name why

let handle_call id params =
  let name = match Yojson.Safe.Util.member "name" params with
    | `String s -> s | _ -> "" in
  let args = match Yojson.Safe.Util.member "arguments" params with
    | `Assoc _ as a -> a | _ -> `Assoc [] in
  match arg_string args "session" with
  | Error e -> reply id (Render.infrastructure_failure e)
  | Ok session_name ->
    if name = "reset" then begin
      (* Server-side only: no worker round trip, and it clears the restart
         note too, since the caller asked for the fresh toplevel. *)
      discard session_name "reset was requested";
      Hashtbl.remove restarted session_name;
      reply id { Render.content =
                   Printf.sprintf "Session %S is now empty." session_name;
                 structured = `Assoc [ "status", `String "reset" ];
                 is_error = false }
    end else
    match request_of_call name args with
    | Error e -> reply id (Render.infrastructure_failure e)
    | Ok request ->
      match session_for session_name with
      | Error e -> reply id (Render.infrastructure_failure e)
      | Ok (s, note) ->
        (* Deadlines are the server's business; the worker knows nothing of
           them, and a describe or require is bounded by the same clock. *)
        match Session.send s request ~timeout:eval_timeout with
        | Error e -> reply id (Render.infrastructure_failure e)
        | Ok () -> Hashtbl.replace pending session_name (id, note)

let handle_packet (packet : Jsonrpc.Packet.t) =
  match packet with
  | Jsonrpc.Packet.Notification _ -> ()          (* nothing to answer *)
  | Jsonrpc.Packet.Request ({ id; method_ = "tools/call"; params } as _r) ->
    let params = match params with Some (`Assoc _ as a) -> a | _ -> `Assoc [] in
    handle_call id params
  | Jsonrpc.Packet.Request r ->
    (match Mcp.dispatch ~call:(fun _ -> assert false) r with
     | Ok result ->
       Mcp.respond stdout (Jsonrpc.Packet.Response (Jsonrpc.Response.ok r.id result))
     | Error e -> reply_error r.id e)
  | Jsonrpc.Packet.Response _ | Jsonrpc.Packet.Batch_response _
  | Jsonrpc.Packet.Batch_call _ ->
    log "ignoring a packet a server should not receive"

let handle_line line =
  if String.trim line <> "" then
    match Jsonrpc.Packet.t_of_yojson (Yojson.Safe.from_string line) with
    | packet -> handle_packet packet
    | exception _ -> log "ignoring an unparseable message"

(* --- worker answers ------------------------------------------------------ *)

let drain_worker name s =
  (* Frame_io blocks until the frame is whole. The worker is already committed
     to writing it, so the wait is bounded by how fast it can, but it does
     delay other sessions' deadlines for that long.
     ponytail: buffer per worker if a big payload ever starves a deadline. *)
  let answer = Session.receive s in
  match Hashtbl.find_opt pending name with
  | None -> log "a worker answered with nothing waiting on it"
  | Some (id, note) ->
    Hashtbl.remove pending name;
    (match answer with
     | Ok (response, payload) ->
       let r = Render.of_response response payload in
       reply id (match note with None -> r | Some n -> Render.with_note n r)
     | Error e ->
       discard name "the worker died during evaluation";
       reply id (Render.infrastructure_failure e))

(* A session killed mid-request still owes its caller an answer. *)
let reap_dead () =
  Hashtbl.iter (fun name s ->
      match Session.state s with
      | Supervision.Dead why when Hashtbl.mem pending name ->
        let id, _ = Hashtbl.find pending name in
        Hashtbl.remove pending name;
        discard name why;
        reply id (Render.infrastructure_failure
                    ("the session was stopped: " ^ why ^
                     ". Its toplevel state is gone; the next call under this \
                      name starts a fresh one."))
      | _ -> ())
    (Hashtbl.copy sessions)

(* --- the loop ------------------------------------------------------------ *)

(* Closing the pipes is enough for an idle worker, which then reads EOF and
   exits. A worker mid-phrase is not reading anything, so it needs the signal. *)
let stop_all () = Hashtbl.iter (fun _ s -> Session.kill s "server exiting") sessions

(* Once stdin closes the client has said goodbye, but a request already at a
   worker still deserves its answer: otherwise piping a single call in gives
   silence. Stop reading, keep serving, exit when nothing is outstanding. *)
let stdin_open = ref true

let () =
  at_exit stop_all;
  List.iter (fun signal ->
      Sys.set_signal signal (Sys.Signal_handle (fun _ -> exit 0)))
    [ Sys.sigterm; Sys.sighup ];
  let leftover = ref "" in
  let chunk = Bytes.create 65536 in
  let rec loop () =
    let busy =
      Hashtbl.fold (fun name s acc ->
          if Session.is_busy s then (name, s) :: acc else acc) sessions [] in
    let timeout =
      Hashtbl.fold (fun _ s acc ->
          match Session.deadline s, acc with
          | Some d, Some a -> Some (Float.min d a)
          | Some d, None -> Some d
          | None, acc -> acc) sessions None
      |> function
      | None -> -1.0
      | Some d -> Float.max 0.0 (d -. Unix.gettimeofday ())
    in
    if (not !stdin_open) && Hashtbl.length pending = 0 then exit 0;
    let watch =
      (if !stdin_open then [ Unix.stdin ] else [])
      @ List.map (fun (_, s) -> Session.fd s) busy in
    match Unix.select watch [] [] timeout with
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> loop ()
    | ready, _, _ ->
      if ready = [] then begin
        (* A deadline expired: interrupt first, since that leaves the toplevel
           usable, and kill only if the interrupt goes unanswered. *)
        let now = Unix.gettimeofday () in
        Hashtbl.iter (fun _ s ->
            match Session.deadline s with
            | Some d when d <= now -> Session.on_deadline s ~grace
            | _ -> ()) sessions;
        reap_dead ()
      end else begin
        List.iter (fun fd ->
            if fd = Unix.stdin then begin
              match Unix.read Unix.stdin chunk 0 (Bytes.length chunk) with
              | 0 -> stdin_open := false           (* the client hung up *)
              | n ->
                let lines, rest =
                  Line_reader.split (!leftover ^ Bytes.sub_string chunk 0 n) in
                leftover := rest;
                List.iter handle_line lines
              | exception Unix.Unix_error (Unix.EINTR, _, _) -> ()
            end else
              match List.find_opt (fun (_, s) -> Session.fd s = fd) busy with
              | Some (name, s) -> drain_worker name s
              | None -> ()) ready
      end;
      loop ()
  in
  log "ready";
  loop ()
