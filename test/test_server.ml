(* Drives the server binary the way an MCP client does: newline-delimited
   JSON-RPC on stdin and stdout, with a real worker behind it. This is the
   only cover the select loop has. *)

let server_path = "../bin/main.exe"
let worker_path = "../worker/main.bc.exe"

type client = { ic : in_channel; oc : out_channel; pid : int }

let start () =
  Unix.putenv "CAMLKIT_WORKER" worker_path;
  (* a findlib package carrying an automatic toplevel printer *)
  Unix.putenv "OCAMLPATH" (Filename.concat (Sys.getcwd ()) "fixtures");
  (* cloexec: OCaml defaults it to false, so without this the server, and then
     its workers, inherit the ends we keep. *)
  let in_r, in_w = Unix.pipe ~cloexec:true () in
  let out_r, out_w = Unix.pipe ~cloexec:true () in
  let devnull = Unix.openfile "/dev/null" [ Unix.O_WRONLY ] 0 in
  let pid = Unix.create_process server_path [| server_path |] in_r out_w devnull in
  Unix.close in_r; Unix.close out_w; Unix.close devnull;
  { ic = Unix.in_channel_of_descr out_r; oc = Unix.out_channel_of_descr in_w; pid }

(* SIGTERM, not SIGKILL: the server cleans up its workers on the way out, and
   SIGKILL would skip that and strand any worker mid-phrase. *)
let stop c =
  close_out_noerr c.oc;
  (try Unix.kill c.pid Sys.sigterm with Unix.Unix_error _ -> ());
  let rec wait n =
    match Unix.waitpid [ Unix.WNOHANG ] c.pid with
    | 0, _ when n > 0 -> Unix.sleepf 0.05; wait (n - 1)
    | 0, _ ->
      (try Unix.kill c.pid Sys.sigkill with Unix.Unix_error _ -> ());
      (try ignore (Unix.waitpid [] c.pid) with Unix.Unix_error _ -> ())
    | _ -> ()
    | exception Unix.Unix_error _ -> ()
  in
  wait 40;
  close_in_noerr c.ic

let rpc c ~id ~meth ~params =
  let request =
    `Assoc [ "jsonrpc", `String "2.0"; "id", `Int id;
             "method", `String meth; "params", params ] in
  output_string c.oc (Yojson.Safe.to_string request); output_char c.oc '\n';
  flush c.oc;
  Yojson.Safe.from_string (input_line c.ic)

let result j = Yojson.Safe.Util.member "result" j

let call c ~id ~tool ~args =
  result (rpc c ~id ~meth:"tools/call"
            ~params:(`Assoc [ "name", `String tool; "arguments", args ]))

let text r =
  match Yojson.Safe.Util.member "content" r with
  | `List (c :: _) -> Yojson.Safe.Util.(member "text" c |> to_string)
  | _ -> ""

let is_error r =
  match Yojson.Safe.Util.member "isError" r with `Bool b -> b | _ -> false

let status r =
  Yojson.Safe.Util.(member "structuredContent" r |> member "status" |> to_string)

let has needle hay =
  let re = Str.regexp_string needle in
  try ignore (Str.search_forward re hay 0); true with Not_found -> false

let with_server f = let c = start () in Fun.protect ~finally:(fun () -> stop c) (fun () -> f c)

(* A client refuses to connect to a server that answers initialize with a
   revision it does not speak, so the version asked for is the version agreed.
   Claude Code sends 2025-11-25. *)
let test_initialize_agrees_on_the_client_version () =
  with_server @@ fun c ->
  let ask v =
    let r = result (rpc c ~id:1 ~meth:"initialize"
                      ~params:(`Assoc [ "protocolVersion", `String v ])) in
    Yojson.Safe.Util.(member "protocolVersion" r |> to_string) in
  Alcotest.(check string) "echoes what the client speaks" "2025-11-25"
    (ask "2025-11-25");
  Alcotest.(check string) "and a different one too" "2025-06-18"
    (ask "2025-06-18")

let test_handshake () =
  with_server @@ fun c ->
  let r = result (rpc c ~id:1 ~meth:"initialize" ~params:(`Assoc [])) in
  Alcotest.(check bool) "initialize is answered, though the spec retired it" true
    (Yojson.Safe.Util.(member "serverInfo" r) <> `Null);
  let r = result (rpc c ~id:2 ~meth:"server/discover" ~params:(`Assoc [])) in
  Alcotest.(check bool) "and so is server/discover" true
    (Yojson.Safe.Util.(member "serverInfo" r) <> `Null)

let test_tools_listed () =
  with_server @@ fun c ->
  let r = result (rpc c ~id:1 ~meth:"tools/list" ~params:(`Assoc [])) in
  let names =
    Yojson.Safe.Util.(member "tools" r |> to_list
                      |> List.map (fun t -> member "name" t |> to_string)) in
  Alcotest.(check (slist string compare)) "the tools"
    [ "continue"; "describe"; "document"; "eval"; "inspect"; "load"; "locate";
      "outline"; "require"; "reset"; "search_type"; "signature"; "type_at";
      "uses" ] names;
  let schemas =
    Yojson.Safe.Util.(member "tools" r |> to_list
                      |> List.filter (fun t -> member "outputSchema" t <> `Null)
                      |> List.map (fun t -> member "name" t |> to_string)) in
  Alcotest.(check (slist string compare)) "every tool declares an output schema"
    [ "continue"; "describe"; "document"; "eval"; "inspect"; "load"; "locate";
      "outline"; "require"; "reset"; "search_type"; "signature"; "type_at";
      "uses" ] schemas

let test_eval_through_the_loop () =
  with_server @@ fun c ->
  let args code = `Assoc [ "session", `String "s"; "code", `String code ] in
  let r = call c ~id:1 ~tool:"eval" ~args:(args "let x = 6 * 7;;") in
  Alcotest.(check bool) "a binding renders" true (has "val x : int = 42" (text r));
  Alcotest.(check bool) "and is not an error" false (is_error r);
  let r = call c ~id:2 ~tool:"eval" ~args:(args "x + 1;;") in
  Alcotest.(check bool) "state persists across calls" true (has "43" (text r))

(* Reported from a session: whether an autorun setting had stuck could only be
   found out by evaluating a second probe, and a promise that had been run
   looked exactly like a plain value. Both answers are now in the result. *)
let test_autorun_is_visible_in_the_result () =
  with_server @@ fun c ->
  let open Yojson.Safe.Util in
  let eval ?autorun code =
    let args =
      `Assoc ([ "session", `String "s"; "code", `String code ]
              @ (match autorun with
                  | None -> []
                  | Some names ->
                    [ "autorun", `List (List.map (fun n -> `String n) names) ]))
    in
    call c ~id:1 ~tool:"eval" ~args
  in
  let autorun_of r = member "structuredContent" r |> member "autorun" in
  let r = eval "1;;" in
  Alcotest.(check bool) "the default setting is reported" true
    (autorun_of r = `List [ `String "lwt"; `String "async" ]);
  let r = eval ~autorun:[] "1;;" in
  Alcotest.(check bool) "and so is an empty one, which omitting cannot say"
    true (autorun_of r = `List []);
  let r = eval "1;;" in
  Alcotest.(check bool) "which persists without being repeated" true
    (autorun_of r = `List []);
  (* a rewritten phrase says so, in the structure and in the transcript *)
  let r = call c ~id:2 ~tool:"require"
      ~args:(`Assoc [ "session", `String "s";
                      "packages", `List [ `String "lwt.unix" ] ]) in
  if status r <> "ok" then Alcotest.fail "lwt.unix is needed for this test";
  let r = eval ~autorun:[ "lwt" ] "Lwt.return 42;;" in
  let ran =
    member "structuredContent" r |> member "phrases" |> to_list |> List.hd
    |> member "ran" in
  Alcotest.(check bool) "the phrase names the rule that ran it" true
    (ran = `String "lwt");
  Alcotest.(check bool) "and the transcript says the promise was run" true
    (has "[autorun lwt" (text r))

(* A failed phrase is a successful call: isError means the server failed at its
   own job, not that the code was wrong. *)
(* Without debug events a raise inside evaluated code reports "Called from
   unknown location", so an agent cannot tell which of its own expressions
   raised. The positions are into the code the caller sent, which is the same
   frame of reference as the spans a failure already carries. *)
let test_a_raise_can_be_located () =
  with_server @@ fun c ->
  let args code = `Assoc [ "session", `String "bt"; "code", `String code ] in
  ignore (call c ~id:1 ~tool:"eval" ~args:(args "Printexc.record_backtrace true;;"));
  ignore (call c ~id:2 ~tool:"eval"
            ~args:(args "let boom x = if x > 0 then failwith \"here\" else x;;"));
  let r = call c ~id:3 ~tool:"eval"
      ~args:(args "(try ignore (boom 1) with _ -> \
                   print_string (Printexc.get_backtrace ()));;") in
  Alcotest.(check bool) "the backtrace names the phrase it came from" true
    (has "//toplevel//" (text r))

let test_type_error_is_not_is_error () =
  with_server @@ fun c ->
  let r = call c ~id:1 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "s"; "code", `String "1 + true;;" ]) in
  Alcotest.(check bool) "not flagged as a tool error" false (is_error r);
  Alcotest.(check string) "but reported as failed" "failed" (status r);
  Alcotest.(check bool) "and says nothing ran" true (has "Nothing was executed" (text r))

let test_unknown_tool_is_is_error () =
  with_server @@ fun c ->
  let r = call c ~id:1 ~tool:"nope" ~args:(`Assoc [ "session", `String "s" ]) in
  Alcotest.(check bool) "an unusable call is a tool error" true (is_error r)

let test_sessions_are_independent () =
  with_server @@ fun c ->
  let args s code = `Assoc [ "session", `String s; "code", `String code ] in
  ignore (call c ~id:1 ~tool:"eval" ~args:(args "one" "let secret = 1;;"));
  let r = call c ~id:2 ~tool:"eval" ~args:(args "two" "secret;;") in
  Alcotest.(check string) "another session cannot see it" "failed" (status r)

(* The loop must keep serving while a session is wedged, which is the whole
   reason it selects rather than blocking. *)
let test_a_stuck_session_does_not_block_the_server () =
  with_server @@ fun c ->
  let spin = `Assoc [ "session", `String "busy";
                      "code", `String "let rec s n = s (n + 1) in s 0;;" ] in
  let request =
    `Assoc [ "jsonrpc", `String "2.0"; "id", `Int 1; "method", `String "tools/call";
             "params", `Assoc [ "name", `String "eval"; "arguments", spin ] ] in
  output_string c.oc (Yojson.Safe.to_string request); output_char c.oc '\n';
  flush c.oc;
  (* no reply is coming for a while; another session must still work *)
  let r = call c ~id:2 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "free"; "code", `String "1 + 1;;" ]) in
  Alcotest.(check bool) "a second session is served while the first spins" true
    (has "2" (text r))

(* A phrase can take the worker down. The name stays usable afterwards, but
   the replacement toplevel is empty and the first result must say so. *)
let test_worker_death_restarts_the_name () =
  with_server @@ fun c ->
  let args code = `Assoc [ "session", `String "s"; "code", `String code ] in
  ignore (call c ~id:1 ~tool:"eval" ~args:(args "let marker = 1;;"));
  let r = call c ~id:2 ~tool:"eval" ~args:(args "let () = Stdlib.exit 0;;") in
  Alcotest.(check bool) "a worker that exits is an infrastructure failure" true
    (is_error r);
  let r = call c ~id:3 ~tool:"eval" ~args:(args "marker;;") in
  Alcotest.(check bool) "the name works again" false (is_error r);
  Alcotest.(check bool) "and the result says the toplevel is fresh" true
    (has "restarted" (text r));
  Alcotest.(check string) "the old binding is genuinely gone" "failed" (status r);
  (* the note is said once, not on every later call *)
  let r = call c ~id:4 ~tool:"eval" ~args:(args "1 + 1;;") in
  Alcotest.(check bool) "the note is not repeated" false (has "restarted" (text r))

let test_reset () =
  with_server @@ fun c ->
  let args code = `Assoc [ "session", `String "s"; "code", `String code ] in
  ignore (call c ~id:1 ~tool:"eval" ~args:(args "let keep = 7;;"));
  let r = call c ~id:2 ~tool:"eval" ~args:(args "keep;;") in
  Alcotest.(check bool) "the binding is there to start with" false (is_error r);
  let r = call c ~id:3 ~tool:"reset" ~args:(`Assoc [ "session", `String "s" ]) in
  Alcotest.(check string) "reset reports" "reset" (status r);
  let r = call c ~id:4 ~tool:"eval" ~args:(args "keep;;") in
  Alcotest.(check string) "the binding is gone" "failed" (status r);
  Alcotest.(check bool) "and a reset is not reported as a restart" false
    (has "restarted" (text r));
  let r = call c ~id:5 ~tool:"eval" ~args:(args "let keep = 8;;") in
  Alcotest.(check bool) "the session still works" false (is_error r);
  (* A reset can carry the preamble that has to stand in the empty toplevel,
     so nothing reaches the session in between. *)
  let r = call c ~id:6 ~tool:"reset"
      ~args:(`Assoc [ "session", `String "s";
                      "code", `String "let helper x = x * 2;;" ]) in
  Alcotest.(check string) "the carried code is evaluated" "ok" (status r);
  Alcotest.(check bool) "and the reset is said out loud" true
    (has "was reset" (text r));
  let r = call c ~id:7 ~tool:"eval" ~args:(args "helper 21;;") in
  Alcotest.(check bool) "the preamble is standing" true (has "42" (text r));
  Alcotest.(check string) "but the old binding is not" "failed"
    (status (call c ~id:8 ~tool:"eval" ~args:(args "keep;;")));
  (* Nothing is remembered: a plain reset empties the preamble too. *)
  ignore (call c ~id:10 ~tool:"reset" ~args:(`Assoc [ "session", `String "s" ]));
  Alcotest.(check string) "a session carries no preamble" "failed"
    (status (call c ~id:11 ~tool:"eval" ~args:(args "helper 1;;")))

(* utop installs printers for values marked [@@ocaml.toplevel_printer]. That
   lives in UTop_main.Autoprinter, which is internal, reached through
   UTop_main.execute_phrase, which we do not call. Without reimplementing it a
   library's own types print as <abstr>, which undercuts exploring a codebase. *)
let test_automatic_toplevel_printers () =
  with_server @@ fun c ->
  let r = call c ~id:1 ~tool:"require"
      ~args:(`Assoc [ "session", `String "s";
                      "packages", `List [ `String "mylib" ] ]) in
  Alcotest.(check string) "the fixture package loads" "ok" (status r);
  let r = call c ~id:2 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "s"; "code", `String "Mylib.make 5;;" ]) in
  Alcotest.(check bool) "its printer is used, not <abstr>" true
    (has "<mylib holding 5>" (text r));
  Alcotest.(check bool) "so the value is not opaque" false (has "<abstr>" (text r))

(* The other half: a printer defined inside the session. utop finds these by
   walking Env summaries; we fold over the environment instead, so this checks
   the substitute actually behaves the same. *)
let test_in_session_printer () =
  with_server @@ fun c ->
  let args code = `Assoc [ "session", `String "s"; "code", `String code ] in
  let def =
    "module Money : sig\n\
    \  type t\n\
    \  val of_int : int -> t\n\
    \  val pp : Format.formatter -> t -> unit [@@ocaml.toplevel_printer]\n\
     end = struct\n\
    \  type t = int\n\
    \  let of_int x = x\n\
    \  let pp fmt x = Format.fprintf fmt \"$%d.00\" x\n\
     end;;" in
  let r = call c ~id:1 ~tool:"eval" ~args:(args def) in
  Alcotest.(check bool) "the module defines" false (is_error r);
  let r = call c ~id:2 ~tool:"eval" ~args:(args "Money.of_int 12;;") in
  Alcotest.(check bool) "its own printer is used" true (has "$12.00" (text r));
  Alcotest.(check bool) "the abstract type is not opaque" false
    (has "<abstr>" (text r))

(* Closing stdin says goodbye, but a request already at a worker still deserves
   its answer. Without this, piping a single call in gives silence. *)
let test_answers_before_exiting_on_eof () =
  let c = start () in
  let request =
    `Assoc [ "jsonrpc", `String "2.0"; "id", `Int 1; "method", `String "tools/call";
             "params", `Assoc [ "name", `String "eval";
                                "arguments", `Assoc [ "session", `String "s";
                                                      "code", `String "1 + 41;;" ] ] ] in
  output_string c.oc (Yojson.Safe.to_string request); output_char c.oc '\n';
  flush c.oc;
  close_out_noerr c.oc;                    (* goodbye, before the answer exists *)
  let reply = Yojson.Safe.from_string (input_line c.ic) in
  Alcotest.(check bool) "the in-flight request is still answered" true
    (has "42" (text (result reply)));
  (try Unix.kill c.pid Sys.sigkill with Unix.Unix_error _ -> ());
  (try ignore (Unix.waitpid [] c.pid) with Unix.Unix_error _ -> ())

(* dune's private libraries are not findlib packages, so require cannot see
   them. The load tool adds each archive's .objs/byte directory and loads it,
   retrying failures so dependency order settles itself. *)
let test_load_a_project () =
  with_server @@ fun c ->
  let fixtures = Filename.concat (Sys.getcwd ()) "fixtures/mylib" in
  let r = call c ~id:1 ~tool:"load"
      ~args:(`Assoc [ "session", `String "s"; "path", `String fixtures ]) in
  Alcotest.(check bool) "loading succeeds" false (is_error r);
  Alcotest.(check bool) "a load that reused the session says nothing about reset"
    false (has "was reset" (text r));
  Alcotest.(check bool) "and says what it loaded" true (has "mylib" (text r));
  let r = call c ~id:2 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "s"; "code", `String "Mylib.make 5;;" ]) in
  Alcotest.(check bool) "the library's modules are usable" true
    (has "mylib holding 5" (text r))

let test_load_a_missing_path () =
  with_server @@ fun c ->
  let r = call c ~id:1 ~tool:"load"
      ~args:(`Assoc [ "session", `String "s"; "path", `String "/nope/nowhere" ]) in
  Alcotest.(check string) "reported as a failure, not a crash" "failed" (status r);
  Alcotest.(check bool) "and names the path" true (has "/nope/nowhere" (text r))

(* Loading a rebuilt archive into a session that still holds the old one fails
   on an interface mismatch, so reset has to happen before the load, not after. *)
let test_load_with_reset_empties_first () =
  with_server @@ fun c ->
  let fixtures = Filename.concat (Sys.getcwd ()) "fixtures/mylib" in
  let ev code = call c ~id:9 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "s"; "code", `String code ]) in
  ignore (ev "let sentinel = 1;;");
  Alcotest.(check bool) "the binding is there" false (is_error (ev "sentinel;;"));
  let r = call c ~id:2 ~tool:"load"
      ~args:(`Assoc [ "session", `String "s"; "path", `String fixtures;
                      "reset", `Bool true ]) in
  Alcotest.(check bool) "load still succeeds" false (is_error r);
  Alcotest.(check string) "but the session was emptied first" "failed"
    (status (ev "sentinel;;"));
  Alcotest.(check bool) "and the library is loaded in the fresh session" true
    (has "mylib holding 5" (text (ev "Mylib.make 5;;")))

(* A reset empties the toplevel, including the findlib packages a project's
   libraries need to load at all. Reported twice: the rebuild loop was reset,
   require, load. The session remembers what it was told to require. *)
let test_reset_load_restores_required_packages () =
  with_server @@ fun c ->
  let fixtures = Filename.concat (Sys.getcwd ()) "fixtures/mylib" in
  ignore (call c ~id:1 ~tool:"require"
            ~args:(`Assoc [ "session", `String "s";
                            "packages", `List [ `String "yojson" ] ]));
  let r = call c ~id:2 ~tool:"load"
      ~args:(`Assoc [ "session", `String "s"; "path", `String fixtures;
                      "reset", `Bool true ]) in
  Alcotest.(check bool) "the load succeeds after the reset" false (is_error r);
  (* A successful reset-load otherwise reads exactly like one that reused the
     session, so it has to say what it did - and say it accurately, since the
     generic restart note claims the packages are gone. *)
  Alcotest.(check bool) "it says the session was reset" true
    (has "was reset before loading" (text r));
  Alcotest.(check bool) "and that bindings went with it" true
    (has "bindings are gone" (text r));
  Alcotest.(check bool) "and names what it restored" true
    (has "Re-required yojson" (text r));
  Alcotest.(check bool) "without claiming the packages were lost" false
    (has "loaded packages are gone" (text r));
  let r = call c ~id:3 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "s";
                      "code", `String "Yojson.Safe.from_string;;" ]) in
  Alcotest.(check bool) "the required package survived the reset" false
    (is_error r);
  Alcotest.(check string) "genuinely usable" "ok" (status r)

(* An explicit reset means empty, including what was required. *)
let test_explicit_reset_forgets_packages () =
  with_server @@ fun c ->
  ignore (call c ~id:1 ~tool:"require"
            ~args:(`Assoc [ "session", `String "s";
                            "packages", `List [ `String "yojson" ] ]));
  ignore (call c ~id:2 ~tool:"reset" ~args:(`Assoc [ "session", `String "s" ]));
  let r = call c ~id:3 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "s";
                      "code", `String "Yojson.Safe.from_string;;" ]) in
  Alcotest.(check string) "the package is gone too" "failed" (status r)

(* notifications/cancelled: stop the work and send no response. The session
   survives, because an interrupt leaves the toplevel usable. *)
let send_raw c v =
  output_string c.oc (Yojson.Safe.to_string v); output_char c.oc '\n'; flush c.oc

let cancel c id =
  send_raw c
    (`Assoc [ "jsonrpc", `String "2.0";
              "method", `String "notifications/cancelled";
              "params", `Assoc [ "requestId", `Int id;
                                 "reason", `String "test" ] ])

let test_cancellation_stops_work_and_stays_quiet () =
  with_server @@ fun c ->
  send_raw c
    (`Assoc [ "jsonrpc", `String "2.0"; "id", `Int 1;
              "method", `String "tools/call";
              "params", `Assoc [ "name", `String "eval";
                                 "arguments",
                                 `Assoc [ "session", `String "s";
                                          "code", `String
                                            "let rec s n = s (n+1) in s 0;;" ] ] ]);
  Unix.sleepf 0.5;
  cancel c 1;
  (* No response for the cancelled request. The next thing on the wire must be
     the answer to a later call, not a late reply to this one. *)
  let r = call c ~id:2 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "other"; "code", `String "1 + 1;;" ]) in
  Alcotest.(check bool) "a later request is answered normally" true
    (has "2" (text r));
  (* and the cancelled session is usable again, because it was interrupted
     rather than killed *)
  let r = call c ~id:3 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "s"; "code", `String "40 + 2;;" ]) in
  Alcotest.(check bool) "the cancelled session survives" true (has "42" (text r))

(* The race the spec calls out: a cancellation arriving after the work is
   done must be ignored, not crash or confuse the next reply. *)
(* The check is exact: a number and its decimal spelling are different ids.
   Obliging the mismatch would hide a client bug, so the request keeps
   running and the session stays busy. *)
let test_cancelling_with_the_wrong_id_type_does_nothing () =
  with_server @@ fun c ->
  send_raw c
    (`Assoc [ "jsonrpc", `String "2.0"; "id", `Int 7;
              "method", `String "tools/call";
              "params", `Assoc [ "name", `String "eval";
                                 "arguments",
                                 `Assoc [ "session", `String "s";
                                          "code", `String
                                            "let rec s n = s (n+1) in s 0;;" ] ] ]);
  Unix.sleepf 0.5;
  (* the id was issued as a number; cancel with its decimal spelling *)
  send_raw c
    (`Assoc [ "jsonrpc", `String "2.0";
              "method", `String "notifications/cancelled";
              "params", `Assoc [ "requestId", `String "7" ] ]);
  Unix.sleepf 0.5;
  let r = call c ~id:8 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "s"; "code", `String "1 + 1;;" ]) in
  Alcotest.(check bool) "the request was not cancelled, so the session is busy"
    true (has "busy" (text r))

let test_cancelling_a_finished_request_is_ignored () =
  with_server @@ fun c ->
  let r = call c ~id:1 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "s"; "code", `String "1 + 1;;" ]) in
  Alcotest.(check bool) "the request completed" false (is_error r);
  cancel c 1;                       (* too late *)
  cancel c 999;                     (* never existed *)
  let r = call c ~id:2 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "s"; "code", `String "2 + 2;;" ]) in
  Alcotest.(check bool) "the server carries on" true (has "4" (text r))

(* Merlin answers about source rather than values, so these need no session.

   The fixture is written outside this project on purpose: merlin finds a
   dune project's configuration by invoking dune, which would contend for the
   build lock while `dune runtest` holds it. A standalone file needs no
   configuration beyond the stdlib. *)
let with_source f =
  let dir = Filename.temp_dir "camlkit-src" "" in
  let path = Filename.concat dir "sample.ml" in
  let oc = open_out path in
  output_string oc
    "let greet name = \"hello \" ^ name\n\
     type colour = Red | Blue\n\
     let shout name = String.uppercase_ascii (greet name)\n";
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
        (try Sys.remove path with Sys_error _ -> ());
        (try Unix.rmdir dir with Unix.Unix_error _ -> ()))
    (fun () -> f path)

let test_outline () =
  with_server @@ fun c ->
  with_source @@ fun path ->
  let r = call c ~id:1 ~tool:"outline" ~args:(`Assoc [ "file", `String path ]) in
  Alcotest.(check bool) "not an error" false (is_error r);
  let names =
    Yojson.Safe.Util.(
      r |> member "structuredContent" |> member "items" |> to_list
      |> List.map (fun i -> member "name" i |> to_string))
  in
  Alcotest.(check (slist string compare)) "every definition in the file"
    [ "colour"; "greet"; "shout" ] names

let test_type_at () =
  with_server @@ fun c ->
  with_source @@ fun path ->
  (* line 3, on the call to greet *)
  let r = call c ~id:1 ~tool:"type_at"
      ~args:(`Assoc [ "file", `String path; "line", `Int 3; "col", `Int 41 ]) in
  let types =
    Yojson.Safe.Util.(
      r |> member "structuredContent" |> member "enclosings" |> to_list
      |> List.map (fun e -> member "type" e |> to_string))
  in
  Alcotest.(check bool) "the innermost type is reported" true
    (List.exists (fun t -> has "string" t) types)

let test_locate () =
  with_server @@ fun c ->
  with_source @@ fun path ->
  let r = call c ~id:1 ~tool:"locate"
      ~args:(`Assoc [ "file", `String path; "line", `Int 3; "col", `Int 41 ]) in
  let loc = Yojson.Safe.Util.(r |> member "structuredContent" |> member "location") in
  Alcotest.(check int) "greet is defined on line 1" 1
    Yojson.Safe.Util.(loc |> member "pos" |> member "line" |> to_int)

(* Reported from a session: project-scope occurrences silently answered from
   one file when dune's index was missing, so a function used elsewhere looked
   unused. merlin gives no signal at all - class: return, no notification - so
   the index is built first, and when it cannot be, the answer says so rather
   than looking whole. *)
let test_uses_says_when_it_cannot_be_project_wide () =
  with_server @@ fun c ->
  with_source @@ fun path ->
  (* a standalone file, so there is no dune project and no index to build *)
  let r = call c ~id:1 ~tool:"uses"
      ~args:(`Assoc [ "file", `String path; "line", `Int 1; "col", `Int 4 ]) in
  let sc = Yojson.Safe.Util.member "structuredContent" r in
  Alcotest.(check bool) "flagged as not complete" true
    (Yojson.Safe.Util.(member "complete" sc) = `Bool false);
  Alcotest.(check bool) "and says so in the text" true
    (has "INCOMPLETE" (text r));
  Alcotest.(check bool) "naming the command that would fix it" true
    (has "dune build @ocaml-index" (text r))

(* Reported from a session: merlin repeats the innermost enclosing when one
   source range maps to two typedtree nodes, and repeats a search hit when two
   paths to a value collapse to one location. Both are upstream. Exact
   duplicates are dropped here because a repeat is indistinguishable from the
   first - enclosings are strictly nested, so two identical ranges cannot both
   be meaningful. *)
let test_enclosings_are_not_repeated () =
  with_server @@ fun c ->
  with_source @@ fun path ->
  let r = call c ~id:1 ~tool:"type_at"
      ~args:(`Assoc [ "file", `String path; "line", `Int 3; "col", `Int 41 ]) in
  let entries =
    Yojson.Safe.Util.(
      r |> member "structuredContent" |> member "enclosings" |> to_list
      |> List.map Yojson.Safe.to_string)
  in
  let distinct = List.sort_uniq compare entries in
  Alcotest.(check int) "no entry appears twice"
    (List.length distinct) (List.length entries);
  (* the ranges must still be strictly nested, so dedup cannot have eaten a
     real enclosing *)
  Alcotest.(check bool) "and there is more than one enclosing" true
    (List.length entries > 1)

(* A limit is the number of results the caller gets. Dedup runs after the
   query, so asking merlin for exactly the limit and then dropping a duplicate
   returned one short; it now over-fetches and trims afterwards. *)
let test_search_type_fills_its_limit () =
  with_server @@ fun c ->
  with_source @@ fun path ->
  let ask n =
    let r = call c ~id:1 ~tool:"search_type"
        ~args:(`Assoc [ "file", `String path; "line", `Int 1; "col", `Int 4;
                        "query", `String "string -> string"; "limit", `Int n ]) in
    Yojson.Safe.Util.(
      r |> member "structuredContent" |> member "results" |> to_list)
  in
  List.iter
    (fun n ->
       let got = ask n in
       Alcotest.(check int)
         (Printf.sprintf "a limit of %d returns %d" n n) n (List.length got);
       let distinct =
         List.sort_uniq compare (List.map Yojson.Safe.to_string got) in
       Alcotest.(check int) "and none of them repeat"
         (List.length got) (List.length distinct))
    [ 3; 8 ]

(* A phrase stops where the caller wrote a marker, its locals become ordinary
   session values, and the session stays usable while the rest of the phrase
   waits as a value rather than as a blocked process. *)
let test_a_phrase_stops_and_resumes () =
  with_server @@ fun c ->
  let args code = `Assoc [ "session", `String "bp"; "code", `String code ] in
  let r = call c ~id:1 ~tool:"eval"
      ~args:(args "let f n =\n  let x = n * 2 in\n  [%break];\n  x + 1\nin f 20;;") in
  let structured = Yojson.Safe.Util.member "structuredContent" r in
  Alcotest.(check string) "stopped rather than completed" "stopped"
    Yojson.Safe.Util.(member "status" structured |> to_string);
  Alcotest.(check bool) "both locals bound" true
    (has "bp_n : int" (text r) && has "bp_x : int" (text r));
  (* The point of binding them: the caller can compute with them. *)
  let r = call c ~id:2 ~tool:"eval" ~args:(args "bp_x * 3;;") in
  Alcotest.(check bool) "the parked values are usable" true (has "120" (text r));
  let r = call c ~id:3 ~tool:"inspect"
      ~args:(`Assoc [ "session", `String "bp" ]) in
  Alcotest.(check bool) "inspect prints them" true (has "bp_x : int = 40" (text r));
  let r = call c ~id:4 ~tool:"continue"
      ~args:(`Assoc [ "session", `String "bp" ]) in
  Alcotest.(check bool) "the rest of the phrase ran" true (has "41" (text r))

(* A stop suspends the call, not only the phrase that stopped. The phrases
   waiting behind it were dropped silently before this: the loop finished, the
   phrase after it never ran, and nothing said so. *)
let test_resuming_finishes_the_rest_of_the_call () =
  with_server @@ fun c ->
  let r = call c ~id:1 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "bp7"; "code", `String
                        "let total = ref 0;;\n\
                         for i = 1 to 2 do [%break]; total := !total + i done;;\n\
                         print_endline \"the tail of the call\";;" ]) in
  Alcotest.(check bool) "stopped in the loop" true (has "Stopped" (text r));
  ignore (call c ~id:2 ~tool:"continue" ~args:(`Assoc [ "session", `String "bp7" ]));
  let r = call c ~id:3 ~tool:"continue" ~args:(`Assoc [ "session", `String "bp7" ]) in
  Alcotest.(check bool) "the phrase behind the stop ran too" true
    (has "the tail of the call" (text r));
  let r = call c ~id:4 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "bp7"; "code", `String "!total;;" ]) in
  Alcotest.(check bool) "and the loop itself completed" true (has "3" (text r))

(* A local whose type is not expressible outside the phrase cannot be bound.
   The compiler's own refusal is the reason reported, rather than the local
   going silently missing. *)
let test_a_local_that_cannot_be_bound_is_named () =
  with_server @@ fun c ->
  let r = call c ~id:1 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "bp2";
                      "code", `String
                        "let f (type a) (x : a) (y : int) = [%break]; y in f \"s\" 3;;" ]) in
  let structured = Yojson.Safe.Util.member "structuredContent" r in
  let skipped = Yojson.Safe.Util.(member "skipped" structured |> to_list) in
  Alcotest.(check bool) "the typed local is still bound" true
    (has "bp_y : int" (text r));
  Alcotest.(check bool) "the other one is reported, with a reason" true
    (List.exists (fun s ->
         Yojson.Safe.Util.(member "name" s |> to_string) = "x"
         && Yojson.Safe.Util.(member "reason" s |> to_string) <> "") skipped)

(* Binding a local at a polymorphic type would let a later phrase choose any
   type for a value that already has one, and the toplevel then reads it at
   that type. Found by segfaulting a worker with String.length (bp_x : string)
   where bp_x was an int bound at 'a. *)
let test_a_polymorphic_local_is_not_bound () =
  with_server @@ fun c ->
  let r = call c ~id:1 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "bp6";
                      "code", `String
                        "let f x =\n  let n = String.length \"ab\" in\n  \
                         [%break];\n  (x, n)\nin f 42;;" ]) in
  let structured = Yojson.Safe.Util.member "structuredContent" r in
  let named key =
    Yojson.Safe.Util.(member key structured |> to_list
                      |> List.map (fun e -> member "name" e |> to_string)) in
  Alcotest.(check bool) "the monomorphic local is bound" true
    (List.mem "bp_n" (named "bound"));
  Alcotest.(check bool) "the polymorphic one is skipped, not bound" true
    (List.mem "x" (named "skipped") && not (List.mem "bp_x" (named "bound")));
  (* The hole, closed: this must not typecheck. *)
  let r = call c ~id:2 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "bp6";
                      "code", `String "String.length (bp_x : string);;" ]) in
  Alcotest.(check bool) "and the name does not exist" true
    (has "Unbound value bp_x" (text r))

(* Abandoning raises inside the phrase rather than resuming it, so the rest
   does not run but anything it set up to release still is. *)
let test_abandon_runs_the_cleanup () =
  with_server @@ fun c ->
  ignore (call c ~id:1 ~tool:"eval"
            ~args:(`Assoc [ "session", `String "bp3"; "code", `String
                              "Fun.protect ~finally:(fun () -> print_endline \"released\") \
                               (fun () -> [%break]; 7);;" ]));
  let r = call c ~id:2 ~tool:"continue"
      ~args:(`Assoc [ "session", `String "bp3"; "abandon", `Bool true ]) in
  Alcotest.(check bool) "the finaliser ran" true (has "released" (text r));
  Alcotest.(check bool) "and it says what happened" true
    (has "Camlkit_abandoned" (text r))

(* Two parked phrases are independent, so neither can be resumed by guessing. *)
let test_two_parked_phrases_need_an_id () =
  with_server @@ fun c ->
  let args code = `Assoc [ "session", `String "bp4"; "code", `String code ] in
  ignore (call c ~id:1 ~tool:"eval" ~args:(args "let a = 1 in [%break]; a;;"));
  ignore (call c ~id:2 ~tool:"eval" ~args:(args "let b = 2 in [%break]; b;;"));
  let r = call c ~id:3 ~tool:"continue" ~args:(`Assoc [ "session", `String "bp4" ]) in
  Alcotest.(check bool) "it asks which, and lists them" true
    (has "1, 2" (text r));
  let r = call c ~id:4 ~tool:"continue"
      ~args:(`Assoc [ "session", `String "bp4"; "id", `Int 1 ]) in
  Alcotest.(check bool) "the named one resumes" true (has "1" (text r))

(* Stopping escapes the blocking run autorun would wrap the phrase in, which
   would leave the scheduler unable to start another. Refused before anything
   runs rather than left as a trap. *)
let test_a_breakpoint_under_autorun_is_refused () =
  with_server @@ fun c ->
  ignore (call c ~id:1 ~tool:"require"
            ~args:(`Assoc [ "session", `String "bp5";
                            "packages", `List [ `String "lwt.unix" ] ]));
  let r = call c ~id:2 ~tool:"eval"
      ~args:(`Assoc [ "session", `String "bp5"; "code", `String
                        "let h () = [%break]; Lwt.return 5 in h ();;" ]) in
  Alcotest.(check bool) "refused, saying why" true
    (has "autorun will run as a promise" (text r));
  Alcotest.(check bool) "and nothing ran" true (has "Nothing was executed" (text r))

(* A marker that is not a bare expression is not a breakpoint. The compiler
   would call it an uninterpreted extension, which does not say what the right
   form is, so it is refused before typing with a message that does. *)
let test_a_malformed_marker_says_the_right_form () =
  with_server @@ fun c ->
  let refused code =
    let r = call c ~id:1 ~tool:"eval"
        ~args:(`Assoc [ "session", `String "bp8"; "code", `String code ]) in
    has "written [%break]" (text r)
  in
  Alcotest.(check bool) "a payload is refused" true (refused "[%break 1];;");
  Alcotest.(check bool) "a structure item is refused" true
    (refused "module M = struct [%%break] end;;")

(* An effect cannot be performed in a frame the runtime entered. The raw
   Unhandled exception names the worker's internals and tells a caller
   nothing, so the hook turns it into a sentence. *)
let test_a_breakpoint_the_runtime_cannot_reach_says_so () =
  with_server @@ fun c ->
  let args code = `Assoc [ "session", `String "bp9"; "code", `String code ] in
  ignore (call c ~id:1 ~tool:"require"
            ~args:(`Assoc [ "session", `String "bp9";
                            "packages", `List [ `String "unix" ] ]));
  ignore (call c ~id:2 ~tool:"eval"
            ~args:(args "Sys.set_signal Sys.sigusr1 \
                         (Sys.Signal_handle (fun _ -> [%break]));;"));
  let r = call c ~id:3 ~tool:"eval"
      ~args:(args "Unix.kill (Unix.getpid ()) Sys.sigusr1;\n\
                   for _ = 1 to 1_000_000 do ignore (Sys.opaque_identity 1) done;\n\
                   \"survived\";;") in
  Alcotest.(check bool) "it explains the boundary" true
    (has "a frame the runtime entered" (text r));
  (* The session is still usable: this is a phrase failure, not a death. *)
  let r = call c ~id:4 ~tool:"eval" ~args:(args "1 + 1;;") in
  Alcotest.(check bool) "and the session survives" true (has "2" (text r))

(* Documentation by name rather than by position. Merlin infers the namespace
   to search from the node under the cursor even when the name is given, so a
   position inside a module path would answer "Not in environment" about a
   name that is in scope; the server passes its own position instead. This
   asks for a value, which is the case that position would break. *)
let test_document_by_identifier () =
  with_server @@ fun c ->
  with_source @@ fun path ->
  let r = call c ~id:1 ~tool:"document"
      ~args:(`Assoc [ "file", `String path;
                      "identifier", `String "String.concat" ]) in
  Alcotest.(check bool) "not an error" false (is_error r);
  Alcotest.(check bool) "the comment on String.concat" true
    (has "concatenates" (text r))

(* Merlin hides this inside an otherwise successful answer, so without the
   sentinels it would be served as if it were the documentation. *)
let test_document_of_a_name_not_in_scope () =
  with_server @@ fun c ->
  with_source @@ fun path ->
  let r = call c ~id:1 ~tool:"document"
      ~args:(`Assoc [ "file", `String path;
                      "identifier", `String "No.Such.Thing" ]) in
  let structured = Yojson.Safe.Util.member "structuredContent" r in
  Alcotest.(check bool) "an error field, no documentation" true
    (Yojson.Safe.Util.member "error" structured <> `Null
     && Yojson.Safe.Util.member "documentation" structured = `Null)

(* A signature read from an installed package's interfaces: no session, and
   nothing of the package is loaded or run. yojson because this server links
   it, so it is installed wherever the tests run. *)
let test_signature_without_a_session () =
  with_server @@ fun c ->
  let r = call c ~id:1 ~tool:"signature"
      ~args:(`Assoc [ "path", `String "Yojson.Safe.to_string" ]) in
  Alcotest.(check bool) "not an error" false (is_error r);
  Alcotest.(check bool) "the value's type" true (has "?buf:Buffer.t" (text r));
  let structured = Yojson.Safe.Util.member "structuredContent" r in
  Alcotest.(check string) "the package it guessed" "yojson"
    Yojson.Safe.Util.(member "package" structured |> to_string)

(* A package that is not installed is a negative answer, not the server
   failing at its own job, so it says so in a field rather than as isError. *)
let test_signature_of_an_unknown_package () =
  with_server @@ fun c ->
  let r = call c ~id:1 ~tool:"signature"
      ~args:(`Assoc [ "path", `String "Nope.Thing" ]) in
  Alcotest.(check bool) "not isError" false (is_error r);
  let structured = Yojson.Safe.Util.member "structuredContent" r in
  Alcotest.(check bool) "an error field, no signature" true
    (Yojson.Safe.Util.member "error" structured <> `Null
     && Yojson.Safe.Util.member "signature" structured = `Null);
  (* The retry that would fix it is naming the package, and only a guess says
     so: the fields alone have to carry that, not just the text. *)
  Alcotest.(check bool) "the structure says the package was a guess" true
    (Yojson.Safe.Util.member "guessed" structured = `Bool true);
  let named = call c ~id:2 ~tool:"signature"
      ~args:(`Assoc [ "path", `String "Yojson.Safe.to_string";
                      "package", `String "yojson" ]) in
  Alcotest.(check bool) "a package that was given is not a guess" true
    Yojson.Safe.Util.(member "structuredContent" named |> member "guessed"
                      |> (=) `Null)

let test_source_query_on_a_missing_file () =
  with_server @@ fun c ->
  let r = call c ~id:1 ~tool:"outline"
      ~args:(`Assoc [ "file", `String "/nope/nowhere.ml" ]) in
  Alcotest.(check bool) "reported as a failure, not a crash" true (is_error r)

(* A server that is killed outright runs no cleanup, and a worker mid-phrase
   is not reading its pipe either, so it neither sees EOF nor gets told to
   stop. It watches for its parent going away instead. *)
let test_a_killed_server_takes_its_workers_with_it () =
  let c = start () in
  send_raw c
    (`Assoc [ "jsonrpc", `String "2.0"; "id", `Int 1;
              "method", `String "tools/call";
              "params", `Assoc [ "name", `String "eval";
                                 "arguments",
                                 `Assoc [ "session", `String "s";
                                          "code", `String
                                            "let rec s n = s (n+1) in s 0;;" ] ] ]);
  Unix.sleepf 1.5;
  let count () =
    let ic = Unix.open_process_in "pgrep -x main.bc.exe | wc -l" in
    let n = int_of_string (String.trim (input_line ic)) in
    ignore (Unix.close_process_in ic); n
  in
  Alcotest.(check bool) "a worker is running" true (count () > 0);
  (* SIGKILL: nothing the server owns gets to run *)
  (try Unix.kill c.pid Sys.sigkill with Unix.Unix_error _ -> ());
  (try ignore (Unix.waitpid [] c.pid) with Unix.Unix_error _ -> ());
  Unix.sleepf 4.0;
  Alcotest.(check int) "and it does not outlive the server" 0 (count ())

let () =
  Alcotest.run "camlkit-server"
    [ ("mcp",
       [ Alcotest.test_case "both handshakes" `Slow test_handshake;
         Alcotest.test_case "initialize agrees on the client version" `Slow
           test_initialize_agrees_on_the_client_version;
         Alcotest.test_case "tools listed" `Slow test_tools_listed ]);
      ("tools",
       [ Alcotest.test_case "eval through the loop" `Slow test_eval_through_the_loop;
         Alcotest.test_case "a raise can be located" `Slow
           test_a_raise_can_be_located;
         Alcotest.test_case "type error is not isError" `Slow
           test_type_error_is_not_is_error;
         Alcotest.test_case "unknown tool is isError" `Slow
           test_unknown_tool_is_is_error;
         Alcotest.test_case "sessions are independent" `Slow
           test_sessions_are_independent;
         Alcotest.test_case "a stuck session does not block the server" `Slow
           test_a_stuck_session_does_not_block_the_server;
         Alcotest.test_case "answers before exiting on eof" `Slow
           test_answers_before_exiting_on_eof;
         Alcotest.test_case "autorun is visible in the result" `Slow
           test_autorun_is_visible_in_the_result ]);
      ("printers",
       [ Alcotest.test_case "automatic toplevel printers" `Slow
           test_automatic_toplevel_printers;
         Alcotest.test_case "in-session printer" `Slow test_in_session_printer ]);
      ("load",
       [ Alcotest.test_case "load a project" `Slow test_load_a_project;
         Alcotest.test_case "missing path" `Slow test_load_a_missing_path;
         Alcotest.test_case "reset empties first" `Slow
           test_load_with_reset_empties_first;
         Alcotest.test_case "reset-load restores required packages" `Slow
           test_reset_load_restores_required_packages;
         Alcotest.test_case "explicit reset forgets packages" `Slow
           test_explicit_reset_forgets_packages ]);
      ("breakpoints",
       [ Alcotest.test_case "a phrase stops and resumes" `Slow
           test_a_phrase_stops_and_resumes;
         Alcotest.test_case "resuming finishes the rest of the call" `Slow
           test_resuming_finishes_the_rest_of_the_call;
         Alcotest.test_case "a local that cannot be bound is named" `Slow
           test_a_local_that_cannot_be_bound_is_named;
         Alcotest.test_case "a polymorphic local is not bound" `Slow
           test_a_polymorphic_local_is_not_bound;
         Alcotest.test_case "abandon runs the cleanup" `Slow
           test_abandon_runs_the_cleanup;
         Alcotest.test_case "two parked phrases need an id" `Slow
           test_two_parked_phrases_need_an_id;
         Alcotest.test_case "a breakpoint under autorun is refused" `Slow
           test_a_breakpoint_under_autorun_is_refused;
         Alcotest.test_case "a malformed marker says the right form" `Slow
           test_a_malformed_marker_says_the_right_form;
         Alcotest.test_case "a breakpoint the runtime cannot reach says so" `Slow
           test_a_breakpoint_the_runtime_cannot_reach_says_so ]);
      ("source",
       [ Alcotest.test_case "outline" `Slow test_outline;
         Alcotest.test_case "type at a position" `Slow test_type_at;
         Alcotest.test_case "locate a definition" `Slow test_locate;
         Alcotest.test_case "a missing file fails cleanly" `Slow
           test_source_query_on_a_missing_file;
         Alcotest.test_case "uses flags an answer it could not complete" `Slow
           test_uses_says_when_it_cannot_be_project_wide;
         Alcotest.test_case "enclosings are not repeated" `Slow
           test_enclosings_are_not_repeated;
         Alcotest.test_case "search_type fills its limit" `Slow
           test_search_type_fills_its_limit;
         Alcotest.test_case "document by identifier" `Slow
           test_document_by_identifier;
         Alcotest.test_case "document a name not in scope" `Slow
           test_document_of_a_name_not_in_scope;
         Alcotest.test_case "signature without a session" `Slow
           test_signature_without_a_session;
         Alcotest.test_case "signature of an unknown package" `Slow
           test_signature_of_an_unknown_package ]);
      ("lifetime",
       [ Alcotest.test_case "a killed server takes its workers with it" `Slow
           test_a_killed_server_takes_its_workers_with_it ]);
      ("cancellation",
       [ Alcotest.test_case "stops work and stays quiet" `Slow
           test_cancellation_stops_work_and_stays_quiet;
         Alcotest.test_case "cancelling a finished request is ignored" `Slow
           test_cancelling_a_finished_request_is_ignored;
         Alcotest.test_case "the wrong id type does nothing" `Slow
           test_cancelling_with_the_wrong_id_type_does_nothing ]);
      ("sessions",
       [ Alcotest.test_case "worker death restarts the name" `Slow
           test_worker_death_restarts_the_name;
         Alcotest.test_case "reset" `Slow test_reset ]) ]
