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

(* JSON-RPC ids waiting on a worker, keyed by session name, with a note to
   attach to the reply. A session holds at most one, because a second
   evaluation is refused rather than queued. *)
let pending : (string, Jsonrpc.Id.t * string option) Hashtbl.t = Hashtbl.create 8

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

let log fmt = Printf.ksprintf (fun s -> prerr_endline ("camlkit: " ^ s)) fmt

let reply id (r : Render.t) =
  Mcp.respond stdout
    (Jsonrpc.Packet.Response
       (Jsonrpc.Response.ok id (Mcp.tool_result ~structured:r.Render.structured
                                  ~is_error:r.Render.is_error
                                  [ Mcp.text r.Render.content ])))

let reply_error id (e : Jsonrpc.Response.Error.t) =
  Mcp.respond stdout (Jsonrpc.Packet.Response (Jsonrpc.Response.error id e))

let arg_string args name =
  match Yojson.Safe.Util.member name args with
  | `String s -> Ok s
  | `Null -> Error (Printf.sprintf "missing required argument %S" name)
  | _ -> Error (Printf.sprintf "argument %S must be a string" name)

(* --- source queries ------------------------------------------------------ *)

(* These ask merlin about code as written, so they need no session and no
   worker: they answer inside this call rather than going through pending. *)

let arg_int args name =
  match Yojson.Safe.Util.member name args with
  | `Int n -> Ok n
  | `Null -> Error (Printf.sprintf "missing required argument %S" name)
  | _ -> Error (Printf.sprintf "argument %S must be an integer" name)

let is_source_query = function
  | "locate" | "type_at" | "outline" | "uses" | "search_type" | "document" ->
    true
  | _ -> false

(* Also session-less, but it asks the switch rather than merlin: what an
   installed package holds, read from its interfaces without loading it. *)
let signature_call id args =
  match arg_string args "path" with
  | Error e -> reply id (Render.infrastructure_failure e)
  | Ok path ->
    let given = match Yojson.Safe.Util.member "package" args with
      | `String p -> Some p | _ -> None in
    let package = Option.value given ~default:(Signature.package_of path) in
    (* A package or a path that is not there is a negative answer, not the
       server failing at its own job, so it is not isError. *)
    let content, fields = match Signature.show ~package ~path with
      | Ok signature ->
        (signature, [ "signature", `String signature ])
      | Error e ->
        (* The guess is right for most packages and wrong for the rest, and
           the caller cannot tell which without being told. *)
        ((match given with
          | Some _ -> e
          | None ->
            Printf.sprintf
              "%s\n\nThe package was guessed from the path. Name it \
               explicitly if it is not %s." e package),
         [ "error", `String e ])
    in
    (* In the structure too, not only in the text: a caller acting on the
       fields alone has to be able to tell a package that is absent from a
       guess that was wrong, and retrying with an explicit package is the
       whole difference. *)
    let fields = match given with
      | Some _ -> fields
      | None -> ("guessed", `Bool true) :: fields in
    reply id { Render.content;
               structured = `Assoc (("package", `String package) :: fields);
               is_error = false }

let source_query id name args =
  let ( let* ) = Result.bind in
  let requested_limit =
    match Yojson.Safe.Util.member "limit" args with
    | `Int n when n > 0 -> Some n
    | _ -> None
  in
  let at () =
    let* line = arg_int args "line" in
    let* col = arg_int args "col" in
    Ok [ "-position"; Merlin.position line col ]
  in
  let run () =
    let* file = arg_string args "file" in
    match name with
    | "outline" -> Merlin.query ~command:"outline" ~args:[] ~file
    | "locate" ->
      let* pos = at () in
      Merlin.query ~command:"locate" ~args:pos ~file
    | "type_at" ->
      let* pos = at () in
      Merlin.query ~command:"type-enclosing" ~args:pos ~file
    | "uses" ->
      let* line = arg_int args "line" in
      let* col = arg_int args "col" in
      let scope = match Yojson.Safe.Util.member "scope" args with
        | `String s -> s | _ -> "project" in
      (* Project scope is silently buffer scope without dune's index, so build
         it first rather than return a complete-looking partial answer. *)
      let index =
        if scope = "project" then Merlin.ensure_index file else Ok () in
      let* value =
        Merlin.query ~command:"occurrences"
          ~args:[ "-identifier-at"; Merlin.position line col; "-scope"; scope ]
          ~file
      in
      Ok (match index with
          | Ok () -> value
          | Error why -> `Assoc [ "incomplete", `String why; "value", value ])
    | "document" ->
      (* Two ways to ask, and the schema cannot say they are exclusive, so the
         check is here: both would silently ignore the position, and neither
         would complain about a missing line rather than about the real
         mistake. *)
      let named = Yojson.Safe.Util.member "identifier" args <> `Null in
      let positioned =
        Yojson.Safe.Util.member "line" args <> `Null
        || Yojson.Safe.Util.member "col" args <> `Null
      in
      (match named, positioned with
       | true, true ->
         Error
           "give identifier, or line and col, not both: an identifier is \
            looked up in the file's environment and needs no position"
       | false, false ->
         Error
           "give identifier for a name in scope in that file, or line and col \
            for whatever is at that position"
       | true, false ->
         let* identifier = arg_string args "identifier" in
         (* Not the caller's position: see Merlin.neutral_position. *)
         Merlin.query ~command:"document"
           ~args:[ "-position"; Merlin.neutral_position;
                   "-identifier"; identifier ] ~file
       | false, true ->
         let* pos = at () in
         Merlin.query ~command:"document" ~args:pos ~file)
    | "search_type" ->
      let* pos = at () in
      let* query = arg_string args "query" in
      (* Ask for more than was requested, because duplicates are dropped below
         and a limit should mean the number of results the caller gets, not
         the number merlin happened to emit. Trimmed back afterwards. *)
      let limit = match requested_limit with
        | Some n -> [ "-limit"; string_of_int (n * 2) ] | None -> [] in
      Merlin.query ~command:"search-by-type"
        ~args:(pos @ [ "-query"; query ] @ limit) ~file
    | other -> Error ("no such source query: " ^ other)
  in
  (* HACK: papering over duplicate entries from merlin. The bug is upstream,
     not here; merlin returns these repeats itself.

     type-enclosing returns the innermost enclosing twice when one source
     range maps to two typedtree nodes, which is common for an identifier in
     an application position. Reproduced at lib/session.ml 41:24, where the
     first two entries are byte-identical. search-by-type returns a value
     twice when two paths to it collapse to one location.

     Dropping entries identical to an earlier one is safe for both, because a
     repeat is indistinguishable from the first: enclosings are strictly
     nested, so two identical ranges cannot both be meaningful, and two hits
     at one file position are the same hit. An exact duplicate carries no
     information, so removing it loses none.

     Remove this once merlin stops emitting them. Nothing else depends on it,
     and the test "enclosings are not repeated" would then pass without it. *)
  let dedup = function
    | `List items ->
      let seen = Hashtbl.create 16 in
      `List (List.filter
               (fun item ->
                  let key = Yojson.Safe.to_string item in
                  if Hashtbl.mem seen key then false
                  else (Hashtbl.add seen key (); true))
               items)
    | other -> other
  in
  match run () with
  | Error e -> reply id (Render.infrastructure_failure e)
  (* Documentation is one string, not a list of results, and merlin hides its
     failures inside it, so it is neither deduped nor trimmed nor pretty-
     printed as JSON. *)
  | Ok value when name = "document" ->
    let content, fields = match Merlin.documentation value with
      | Ok doc -> (doc, [ "documentation", `String doc ])
      | Error why -> (why, [ "error", `String why ])
    in
    (* Not isError: a name with no comment on it is an answer. *)
    reply id { Render.content; structured = `Assoc fields; is_error = false }
  | Ok value ->
    (* merlin already answers in structure; name it so the result says what it
       is, and give the text half something readable. *)
    let key = match name with
      | "locate" -> "location" | "type_at" -> "enclosings"
      | "outline" -> "items" | "uses" -> "occurrences" | _ -> "results" in
    (* An answer that could not be made complete says so, in the structure and
       in the text, rather than looking whole. *)
    let caveat, value =
      match value with
      | `Assoc [ ("incomplete", `String why); ("value", v) ] ->
        ( Some (Printf.sprintf
                  "INCOMPLETE: these are occurrences in this file only. \
                   Project-wide results need dune's index, which could not be \
                   built here (%s). Run `dune build @ocaml-index` in the \
                   project and ask again." why),
          v )
      | v -> (None, v)
    in
    let value = dedup value in
    (* Trim only after dedup, so the caller gets the number it asked for. *)
    let value =
      match requested_limit, value with
      | Some n, `List items when List.length items > n ->
        `List (List.filteri (fun i _ -> i < n) items)
      | _ -> value
    in
    let summary =
      match value with
      | `List [] -> "no results"
      | `List l ->
        Printf.sprintf "%d result%s\n%s" (List.length l)
          (if List.length l = 1 then "" else "s")
          (Yojson.Safe.pretty_to_string value)
      | v -> Yojson.Safe.pretty_to_string v
    in
    let summary = match caveat with
      | None -> summary | Some c -> c ^ "\n\n" ^ summary in
    let fields = [ key, value ] in
    let fields = match caveat with
      | None -> fields
      | Some c -> ("complete", `Bool false) :: ("caveat", `String c) :: fields in
    reply id { Render.content = summary;
               structured = `Assoc fields;
               is_error = false }


(* --- tool calls --------------------------------------------------------- *)

let arg_strings args name =
  match Yojson.Safe.Util.member name args with
  | `List items ->
    (try Ok (List.map Yojson.Safe.Util.to_string items)
     with _ -> Error (Printf.sprintf "argument %S must be a list of strings" name))
  | `Null -> Error (Printf.sprintf "missing required argument %S" name)
  | _ -> Error (Printf.sprintf "argument %S must be a list of strings" name)

let request_of_call name args =
  match name with
  | "eval" ->
    let autorun =
      match Yojson.Safe.Util.member "autorun" args with
      | `List l -> Some (List.filter_map (function `String s -> Some s | _ -> None) l)
      | _ -> None
    in
    (match arg_string args "code" with
     | Error _ as e -> e
     | Ok source -> Ok (Msg.Eval { source; autorun }))
  | "describe" -> Result.map (fun p -> Msg.Describe p) (arg_string args "path")
  | "continue" ->
    let id = match Yojson.Safe.Util.member "id" args with
      | `Int i -> Some i | _ -> None in
    Ok (Msg.Continue { id; abandon =
                               Yojson.Safe.Util.member "abandon" args = `Bool true })
  | "inspect" ->
    let id = match Yojson.Safe.Util.member "id" args with
      | `Int i -> Some i | _ -> None in
    Ok (Msg.Inspect { id })
  | "require" -> Result.map (fun p -> Msg.Require p) (arg_strings args "packages")
  | "load" -> assert false                       (* handled before we get here *)
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
  if is_source_query name then source_query id name args
  else if name = "signature" then signature_call id args else
  match arg_string args "session" with
  | Error e -> reply id (Render.infrastructure_failure e)
  | Ok session_name ->
    if name = "load" then begin
      let strings key =
        match Yojson.Safe.Util.member key args with
        | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
        | _ -> [] in
      (* Reloading a rebuilt archive into a session that still holds the old
         one fails on an interface mismatch, so the reset has to happen in
         that order, server-side, before the request reaches a worker. *)
      let resetting = Yojson.Safe.Util.member "reset" args = `Bool true in
      if resetting then begin
        discard session_name "reset was requested before loading";
        (* Not the generic restart note: that one says the required packages
           are gone, while this call is about to put them back. Suppress it
           and say what actually happened instead, because a successful
           reset-load otherwise reads exactly like one that reused the
           session, and the caller would have to probe a binding to tell. *)
        Hashtbl.remove restarted session_name
      end;
      let asked = strings "packages" in
      remember_required session_name asked;
      (* Only replay after a reset: otherwise the session still has them. *)
      let packages =
        if resetting then Option.value ~default:[] (Hashtbl.find_opt required session_name)
        else asked in
      let reset_note =
        if not resetting then None
        else
          Some (Printf.sprintf
                  "Session %S was reset before loading: earlier bindings are \
                   gone.%s" session_name
                  (match packages with
                   | [] -> ""
                   | ps -> Printf.sprintf " Re-required %s."
                             (String.concat ", " ps)))
      in
      match arg_string args "path" with
      | Error e -> reply id (Render.infrastructure_failure e)
      | Ok path ->
        let request = Msg.Load { path; libraries = strings "libraries"; packages } in
        match session_for session_name with
        | Error e -> reply id (Render.infrastructure_failure e)
        | Ok (s, note) ->
          let note = match reset_note with Some _ -> reset_note | None -> note in
          match Session.send s request ~timeout:eval_timeout with
          | Error e -> reply id (Render.infrastructure_failure e)
          | Ok () -> Hashtbl.replace pending session_name (id, note)
    end else
    if name = "reset" then begin
      (* Clears the restart note too, since the caller asked for the fresh
         toplevel. *)
      discard session_name "reset was requested";
      Hashtbl.remove restarted session_name;
      (* An explicit reset means empty, including what was required. *)
      Hashtbl.remove required session_name;
      match Yojson.Safe.Util.member "code" args with
      (* Bare reset is server-side only: no worker round trip. *)
      | `String code when String.trim code <> "" ->
        (* The preamble rides on the reset rather than following it, so
           nothing can reach the empty toplevel in between. It is an ordinary
           eval otherwise, which is why the result is an eval's: the caller
           needs to see whether its own code typechecked. Nothing is
           remembered - a session carries no preamble, and the next reset
           empties this one too. *)
        (match session_for session_name with
         | Error e -> reply id (Render.infrastructure_failure e)
         | Ok (s, _) ->
           let note =
             Printf.sprintf
               "Session %S was reset; what follows is the code the reset \
                carried, evaluated in the empty toplevel." session_name
           in
           (match Session.send s (Msg.Eval { source = code; autorun = None })
                    ~timeout:eval_timeout with
            | Error e -> reply id (Render.infrastructure_failure e)
            | Ok () -> Hashtbl.replace pending session_name (id, Some note)))
      | _ ->
        reply id { Render.content =
                     Printf.sprintf "Session %S is now empty." session_name;
                   structured = `Assoc [ "status", `String "reset" ];
                   is_error = false }
    end else
    match request_of_call name args with
    | Error e -> reply id (Render.infrastructure_failure e)
    | Ok request ->
      (* Remember what the session was told to require, so a later reset-load
         can restore it instead of making the caller say it twice. *)
      (match request with
       | Msg.Require ps -> remember_required session_name ps
       | Msg.Eval _ | Msg.Describe _ | Msg.Load _
       | Msg.Continue _ | Msg.Inspect _ -> ());
      match session_for session_name with
      | Error e -> reply id (Render.infrastructure_failure e)
      | Ok (s, note) ->
        (* Deadlines are the server's business; the worker knows nothing of
           them, and a describe or require is bounded by the same clock. *)
        match Session.send s request ~timeout:eval_timeout with
        | Error e -> reply id (Render.infrastructure_failure e)
        | Ok () -> Hashtbl.replace pending session_name (id, note)

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
      (fun name (id, _) acc -> if acc = None && p id requested then Some name else acc)
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
          (fun name (id, _) acc ->
             Printf.sprintf "session %S is waiting on %s" name (describe id) :: acc)
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
       let r = Render.of_response response payload in
       reply id (match note with None -> r | Some n -> Render.with_note n r)
     | Error e ->
       discard name "the worker died during evaluation";
       reply id (Render.infrastructure_failure e))

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
