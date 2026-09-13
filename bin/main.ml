(* The server is an I/O multiplexer, so Unix.select covers it: no Eio, no Lwt,
   no threads. It wakes on whichever comes first - a request on stdin, a
   worker's answer, or the earliest pending deadline - which keeps it
   responsive while one session is stuck.

   Nothing here may print to stdout: that descriptor is the MCP channel.
   Diagnostics go to stderr. *)

open Camlkit
open Wire

let eval_timeout = 30.0
let grace = 2.0

let sessions : (string, Session.t) Hashtbl.t = Hashtbl.create 8

(* Calls waiting on a worker, keyed by session name: the JSON-RPC id, which a
   cancellation names; a note for the first result after a restart; and the
   call's typed reply. A session holds at most one, because a second
   evaluation is refused rather than queued. *)
type waiting = {
  id : Jsonrpc.Id.t;
  note : string option;
  answer : (Session_result.t, Tool.failure) result -> unit;
}

let pending : (string, waiting) Hashtbl.t = Hashtbl.create 8

(* findlib packages a session has required. A reset empties the toplevel,
   including those, and a project's own libraries usually cannot load without
   them, so a load that resets replays them first. The caller said which
   packages once; it should not have to say again. *)
let required : (string, string list) Hashtbl.t = Hashtbl.create 8

let remember_required name packages =
  let had = Option.value ~default:[] (Hashtbl.find_opt required name) in
  let fresh = List.filter (fun p -> not (List.mem p had)) packages in
  Hashtbl.replace required name (had @ fresh)

(* Sessions whose pending request was cancelled. The worker still owes us an
   answer, and we still have to read it or the pipe fills and the session
   wedges - we just do not reply with it. *)
let cancelled : (string, unit) Hashtbl.t = Hashtbl.create 8

(* Names whose session died. The name stays usable, but the first result after
   the restart says so, since the new toplevel is empty. *)
let restarted : (string, string) Hashtbl.t = Hashtbl.create 8

let default_session = "main"

let log fmt = Printf.ksprintf (fun s -> prerr_endline ("camlkit: " ^ s)) fmt

let reply id (r : Render.t) =
  Mcp.respond stdout
    (Jsonrpc.Packet.Response
       (Jsonrpc.Response.ok id (Mcp.tool_result ~structured:r.Render.structured
                                  ~is_error:r.Render.is_error
                                  [ Mcp.text r.Render.content ])))

let reply_error id (e : Jsonrpc.Response.Error.t) =
  Mcp.respond stdout (Jsonrpc.Packet.Response (Jsonrpc.Response.error id e))

(* The manual behind a tool's description, which stays a trigger. An unknown
   name is a negative answer that lists what there is, not a failure. See
   ticket 062. *)
type help_args = {
  tool : string option;
  (** Tool name. Omit to list them. *)
} [@@deriving mcp]

type help_result = {
  manual : string;
  tools : string list;
  (** What there is a manual for, when no tool or an unknown one was named. *)
  error : string;
} [@@deriving mcp]

let help_tool =
  Tool.make ~name:"help" ~read_only:true ~idempotent:true ~open_world:false
    ~doc:"A tool's full manual: limits, edge cases and what its result fields \
          mean. Read it before relying on anything a description does not say."
    help_args_mcp help_result_mcp
    (fun { tool } ->
       let none = { manual = ""; tools = []; error = "" } in
       match tool with
       | None -> Ok { none with tools = Guide.topics }
       | Some name ->
         match List.assoc_opt name Guide.manual with
         | Some manual -> Ok { none with manual }
         | None ->
           Ok { none with tools = Guide.topics;
                          error = Printf.sprintf "no manual for %S" name })

(* --- session tools ------------------------------------------------------- *)

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

(* A name is a handle, and most callers want one session. Defaulting it means
   a one-off evaluation needs no invented name. *)
let session_name s = if String.trim s = "" then default_session else s

(* Sends a request and parks the call until the worker answers. [note]
   replaces the restart note, for a call that already says what happened. *)
let send ~id ~reply ?note name request =
  match session_for name with
  | Error e -> reply (Error (Tool.failure e))
  | Ok (s, restart_note) ->
    let note = match note with Some _ -> note | None -> restart_note in
    (* Deadlines are the server's business; the worker knows nothing of them,
       and a describe or require is bounded by the same clock. *)
    match Session.send s request ~timeout:eval_timeout with
    | Error e -> reply (Error (Tool.failure e))
    | Ok () -> Hashtbl.replace pending name { id; note; answer = reply }

type eval_args = {
  session : string; [@default "main"]
  (** Session name, default main. *)
  code : string;
  (** OCaml phrases, each ending in ;;. *)
  check : bool; [@default false]
  (** Typecheck only; nothing runs. *)
  cost : bool; [@default false]
  (** Report time and allocation per phrase. *)
  autorun : string list option;
  (** Promise libraries whose bare promises are run; [] returns the promise. *)
} [@@deriving mcp]

let eval_tool =
  Tool.deferred ~name:"eval"
    ~doc:"Run OCaml in a persistent session: try code, see a value, check a type. \
          Every phrase must typecheck or none run, and #directives are rejected. \
          [%break], [%watch] and [%swap] debug live code."
    eval_args_mcp Session_result.t_mcp
    (fun a ~id ~reply ->
       let autorun = match a.autorun with
         | Some rules -> Msg.Rules rules | None -> Msg.Default_rules in
       send ~id ~reply (session_name a.session)
         (Msg.Eval { source = a.code; autorun; check = a.check; cost = a.cost }))

type describe_args = {
  session : string; [@default "main"]
  (** Session name, default main. *)
  path : string;
  (** Such as List or List.map. *)
} [@@deriving mcp]

let describe_tool =
  Tool.deferred ~name:"describe" ~read_only:true ~idempotent:true ~open_world:false
    ~doc:"Show the signature of a module, value or type a session has. Prefer it \
          to guessing at names."
    describe_args_mcp Session_result.t_mcp
    (fun a ~id ~reply -> send ~id ~reply (session_name a.session) (Msg.Describe a.path))

type require_args = {
  session : string; [@default "main"]
  (** Session name, default main. *)
  packages : string list;
} [@@deriving mcp]

let require_tool =
  Tool.deferred ~name:"require" ~destructive:false ~idempotent:true ~open_world:false
    ~doc:"Load findlib packages into a session."
    require_args_mcp Session_result.t_mcp
    (fun a ~id ~reply ->
       let name = session_name a.session in
       (* Remembered, so a later reset-load can restore them instead of making
          the caller say them twice. *)
       remember_required name a.packages;
       send ~id ~reply name (Msg.Require a.packages))

type load_args = {
  session : string; [@default "main"]
  (** Session name, default main. *)
  path : string option;
  (** Project root; defaults to the server's project. *)
  libraries : string list; [@default []]
  (** Omit to load all. *)
  reset : bool; [@default false]
  (** Empty the session first. *)
} [@@deriving mcp]

let load_tool =
  Tool.deferred ~name:"load" ~destructive:false ~idempotent:true ~open_world:false
    ~doc:"Load a dune project's own libraries into a session. Pass reset after \
          rebuilding."
    load_args_mcp Session_result.t_mcp
    (fun a ~id ~reply ->
       let name = session_name a.session in
       (* Reloading a rebuilt archive into a session that still holds the old
          one fails on an interface mismatch, so the reset has to happen in
          that order, server-side, before the request reaches a worker. *)
       if a.reset then begin
         discard name "reset was requested before loading";
         (* Not the generic restart note, which says the required packages are
            gone while this call is about to put them back. *)
         Hashtbl.remove restarted name
       end;
       (* Only replayed after a reset: otherwise the session still has them. *)
       let packages =
         if a.reset then Option.value ~default:[] (Hashtbl.find_opt required name)
         else [] in
       let note =
         if not a.reset then None
         else
           Some (Printf.sprintf
                   "Session %S was reset before loading: earlier bindings are \
                    gone.%s" name
                   (match packages with
                    | [] -> ""
                    | ps -> Printf.sprintf " Re-required %s." (String.concat ", " ps)))
       in
       (* Defaulting to where the server runs: a client starts it in the
          project it is working on, so the usual load names nothing. *)
       match
         match a.path with
         | Some p -> Some p
         | None -> Wire.Exe.project_root_of (Sys.getcwd ())
       with
       | None ->
         reply (Error (Tool.failure
                         "no path, and the directory the server runs in is not \
                          inside a dune project. Give the project root."))
       | Some path ->
         send ~id ~reply ?note name
           (Msg.Load { path; libraries = a.libraries; packages }))

type reset_args = {
  session : string; [@default "main"]
  (** Session name, default main. *)
  code : string; [@default ""]
  (** Evaluated in the fresh toplevel. *)
} [@@deriving mcp]

let reset_tool =
  Tool.deferred ~name:"reset" ~idempotent:true ~open_world:false
    ~doc:"Empty a session back to a clean toplevel, optionally running code in it."
    reset_args_mcp Session_result.t_mcp
    (fun a ~id ~reply ->
       let name = session_name a.session in
       (* Clears the restart note too, since the caller asked for the fresh
          toplevel, and what was required: an explicit reset means empty. *)
       discard name "reset was requested";
       Hashtbl.remove restarted name;
       Hashtbl.remove required name;
       if String.trim a.code = "" then
         (* Bare reset is server-side only: no worker round trip. *)
         reply (Ok (Session_result.Reset
                      { note = Printf.sprintf "Session %S is now empty." name }))
       else
         (* The preamble rides on the reset rather than following it, so
            nothing can reach the empty toplevel in between. Nothing is
            remembered: the next reset empties this one too. *)
         send ~id ~reply name
           ~note:(Printf.sprintf
                    "Session %S was reset; what follows is the code the reset \
                     carried, evaluated in the empty toplevel." name)
           (Msg.Eval { source = a.code; autorun = Msg.Default_rules; check = false;
                       cost = false }))

type continue_args = {
  session : string; [@default "main"]
  (** Session name, default main. *)
  id : int option;
  (** Parked phrase; omit when there is one. *)
  abandon : bool; [@default false]
  (** Raise inside the phrase instead of resuming. *)
} [@@deriving mcp]

let continue_tool =
  Tool.deferred ~name:"continue"
    ~doc:"Resume or abandon a phrase parked at [%break]."
    continue_args_mcp Session_result.t_mcp
    (fun a ~id ~reply ->
       send ~id ~reply (session_name a.session)
         (Msg.Continue { id = a.id; abandon = a.abandon }))

type inspect_args = {
  session : string; [@default "main"]
  (** Session name, default main. *)
  id : int option;
  (** Parked phrase; omit when there is one. *)
} [@@deriving mcp]

let inspect_tool =
  Tool.deferred ~name:"inspect" ~read_only:true ~idempotent:true ~open_world:false
    ~doc:"See a parked phrase's locals and every watch's recorded values, without \
          resuming."
    inspect_args_mcp Session_result.t_mcp
    (fun a ~id ~reply ->
       send ~id ~reply (session_name a.session) (Msg.Inspect { id = a.id }))

(* A marker is compiled into the code holding it, so it fires whenever that
   code runs. This is what stops one. See docs/wayfinder/tickets/049. *)
type markers_args = {
  session : string; [@default "main"]
  (** Session name, default main. *)
  disarm : string list; [@default []]
  (** Names to turn off. *)
  arm : string list; [@default []]
  (** Names to turn on. *)
  disarm_sites : int list; [@default []]
  (** Site ids to turn off. *)
  arm_sites : int list; [@default []]
  (** Site ids to turn on. *)
  restore : string list; [@default []]
  (** Swapped paths to put back. *)
} [@@deriving mcp]

let markers_tool =
  Tool.deferred ~name:"markers" ~destructive:false ~idempotent:true ~open_world:false
    ~doc:"List, arm and disarm a session's breakpoints and watches; restore \
          swapped functions."
    markers_args_mcp Session_result.t_mcp
    (fun a ~id ~reply ->
       send ~id ~reply (session_name a.session)
         (Msg.Markers { disarm = a.disarm; arm = a.arm; disarm_sites = a.disarm_sites;
                        arm_sites = a.arm_sites; restore = a.restore }))

(* Every tool, declared from its types. See ticket 071. *)
let tools =
  [ eval_tool; describe_tool; require_tool; load_tool; reset_tool; continue_tool;
    inspect_tool; markers_tool; help_tool ]
  @ Queries.all

let handle_call id params =
  let name = match Yojson.Safe.Util.member "name" params with
    | `String s -> s | _ -> "" in
  let args = match Yojson.Safe.Util.member "arguments" params with
    | `Assoc _ as a -> a | _ -> `Assoc [] in
  match List.find_opt (fun (t : Tool.t) -> t.name = name) tools with
  | Some t -> t.call ~id args ~reply:(reply id)
  | None -> reply id (Tool.failure_rendering (Printf.sprintf "no such tool: %s" name))

(* Ids are matched exactly, with no coercion between an integer and its
   decimal spelling: a client knows what it issued. JSON-RPC permits either
   form and the spec's own example uses a string, so both are accepted - what
   is refused is a cancellation whose id only matches after coercion. That is
   a client bug, and silently obliging it would hide it. *)
let id_matches (stored : Jsonrpc.Id.t) json =
  match stored, json with
  | `Int a, `Int b -> a = b
  | `String a, `String b -> a = b
  | _ -> false

let id_matches_loosely (stored : Jsonrpc.Id.t) json =
  match stored, json with
  | `Int a, `String b -> string_of_int a = b
  | `String a, `Int b -> a = string_of_int b
  | _ -> false

(* notifications/cancelled: stop work, free what it holds, and send no
   response for the cancelled request. An interrupt is the right first move
   because it leaves the toplevel usable; if the worker ignores it, the
   deadline already in flight escalates to a kill. *)
let handle_cancelled params =
  let requested = Yojson.Safe.Util.member "requestId" params in
  let reason = match Yojson.Safe.Util.member "reason" params with
    | `String r -> " (" ^ r ^ ")" | _ -> "" in
  let find p =
    Hashtbl.fold
      (fun name (w : waiting) acc -> if acc = None && p w.id requested then Some name else acc)
      pending None
  in
  match find id_matches with
  | None ->
    (* A cancellation for nothing at all is the race the spec expects, and is
       ignored in silence. One that arrives while requests *are* pending is a
       client bug, so name it and say what it could have meant: we hold every
       pending id, so the candidates are known rather than guessed at. *)
    if Hashtbl.length pending > 0 then begin
      let describe (id : Jsonrpc.Id.t) =
        match id with
        | `Int n -> Printf.sprintf "%d (number)" n
        | `String s -> Printf.sprintf "%S (string)" s
      in
      let candidates =
        Hashtbl.fold
          (fun name (w : waiting) acc ->
             Printf.sprintf "session %S is waiting on %s" name (describe w.id) :: acc)
          pending []
      in
      log "ignoring notifications/cancelled for %s: no request was issued with \
           that id. Pending: %s"
        (Yojson.Safe.to_string requested) (String.concat "; " candidates);
      match find id_matches_loosely with
      | Some name ->
        log "  it differs only in JSON type from the id session %S is waiting \
             on. Cancel with the id exactly as it was issued; a number and its \
             decimal spelling are different ids." name
      | None -> ()
    end
  | Some name ->
    match Hashtbl.find_opt sessions name with
    | None -> Hashtbl.remove pending name
    | Some s ->
      log "cancelling the request on session %S%s" name reason;
      Hashtbl.replace cancelled name ();
      Session.on_deadline s ~grace

let handle_packet (packet : Jsonrpc.Packet.t) =
  match packet with
  | Jsonrpc.Packet.Notification { method_ = "notifications/cancelled"; params }
    ->
    handle_cancelled (match params with Some (`Assoc _ as a) -> a | _ -> `Assoc [])
  | Jsonrpc.Packet.Notification _ -> ()          (* nothing to answer *)
  | Jsonrpc.Packet.Request ({ id; method_ = "tools/call"; params } as _r) ->
    let params = match params with Some (`Assoc _ as a) -> a | _ -> `Assoc [] in
    (* One call's surprise is that call's failure. Uncaught, it ended the
       server and every session with it: a merlin diagnostic with no position
       did exactly that. *)
    (try handle_call id params
     with exn ->
       let why = Printexc.to_string exn in
       log "a tool call raised: %s" why;
       reply id (Tool.failure_rendering
                   ("camlkit failed while answering this call: " ^ why)))
  | Jsonrpc.Packet.Request r ->
    (match Mcp.dispatch ~tools ~call:(fun _ -> assert false) r with
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
  | Some w ->
    Hashtbl.remove pending name;
    if Hashtbl.mem cancelled name then begin
      (* Read and discard: the caller is gone, but the session is not, and an
         unread frame would wedge it. *)
      Hashtbl.remove cancelled name;
      match answer with
      | Ok _ -> log "discarded the answer to a cancelled request on %S" name
      | Error e -> discard name e
    end else
    (match answer with
     | Ok (response, payload) ->
       w.answer (Ok (Session_result.of_response ?note:w.note response payload))
     | Error e ->
       let exit_code, signal = Render.exit_status (Session.exited s) in
       discard name "the worker died during evaluation";
       w.answer (Error (Tool.failure ?exit_code ?signal e)))

(* A session killed mid-request still owes its caller an answer. *)
let reap_dead () =
  Hashtbl.iter (fun name s ->
      match Session.state s with
      | Supervision.Dead why when Hashtbl.mem pending name
                                  && Hashtbl.mem cancelled name ->
        (* Nobody is waiting for this one. *)
        Hashtbl.remove pending name;
        Hashtbl.remove cancelled name;
        discard name why
      | Supervision.Dead why when Hashtbl.mem pending name ->
        let w = Hashtbl.find pending name in
        Hashtbl.remove pending name;
        discard name why;
        w.answer (Error (Tool.failure
                           ("the session was stopped: " ^ why ^
                            ". Its toplevel state is gone; the next call under \
                             this name starts a fresh one.")))
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
  (* Before any worker is spawned, so it inherits this, and before merlin or
     dune is run. See ticket 039. *)
  Exe.adopt_switch ();
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
