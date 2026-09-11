(* The server is an I/O multiplexer, so Unix.select covers it: no Eio, no Lwt,
   no threads. It wakes on whichever comes first - a request on stdin, a
   worker's answer, or the earliest pending deadline - which keeps it
   responsive while one session is stuck. *)

open Utop_mcp

let default_timeout = 30.0
let grace = 2.0

let sessions : (string, Session.t) Hashtbl.t = Hashtbl.create 8

let session name =
  match Hashtbl.find_opt sessions name with
  | Some s -> s
  | None -> let s = Session.spawn name in Hashtbl.replace sessions name s; s

(* Requests whose worker has not answered yet, keyed by session name. *)
let pending : (string, Jsonrpc.Id.t) Hashtbl.t = Hashtbl.create 8

let earliest_deadline () =
  Hashtbl.fold (fun _ s acc ->
      match Session.deadline s, acc with
      | Some d, Some a -> Some (Float.min d a)
      | Some d, None -> Some d
      | None, acc -> acc)
    sessions None

let select_timeout () =
  match earliest_deadline () with
  | None -> -1.0                                   (* block until something happens *)
  | Some d -> Float.max 0.0 (d -. Unix.gettimeofday ())

(* TODO: translate a Msg.response plus the raw output segment into an MCP
   tool result, per docs/wayfinder/tickets/004. Structure is decided; the
   field-level mapping is not. *)
let _result_of_response (_r : Wire.Msg.response) (_output : string) = assert false

(* TODO: parse tools/call params, route to the right session, and reply. *)
let _handle_call (_params : Yojson.Safe.t) = assert false

let () =
  let stdin_fd = Unix.stdin in
  let rec loop () =
    let worker_fds =
      Hashtbl.fold (fun _ s acc ->
          if Session.is_busy s then Session.fd s :: acc else acc)
        sessions []
    in
    let ready, _, _ =
      Unix.select (stdin_fd :: worker_fds) [] [] (select_timeout ()) in
    if ready = [] then
      (* Nothing spoke, so a deadline expired: interrupt, then kill on the
         second expiry. A SIGINT leaves the toplevel usable and its bindings
         intact, so killing first would throw away recoverable state. *)
      Hashtbl.iter (fun _ s ->
          match Session.deadline s with
          | Some d when d <= Unix.gettimeofday () -> Session.on_deadline s ~grace
          | _ -> ())
        sessions
    else
      List.iter (fun _fd -> ignore default_timeout; ignore pending; ignore session)
        ready;
    loop ()
  in
  ignore Mcp.dispatch;
  ignore loop;
  prerr_endline "utop-mcp: scaffolding only, main loop not wired yet"
