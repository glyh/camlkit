(* Drives the server binary the way an MCP client does: newline-delimited
   JSON-RPC on stdin and stdout, with a real worker behind it. This is the
   only cover the select loop has. *)

let server_path = "../bin/main.exe"
let worker_path = "../worker/main.bc.exe"

type client = { ic : in_channel; oc : out_channel; pid : int }

let start () =
  Unix.putenv "UTOP_MCP_WORKER" worker_path;
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
    [ "describe"; "eval"; "load"; "require"; "reset" ] names;
  let schemas =
    Yojson.Safe.Util.(member "tools" r |> to_list
                      |> List.filter (fun t -> member "outputSchema" t <> `Null)
                      |> List.map (fun t -> member "name" t |> to_string)) in
  Alcotest.(check (slist string compare)) "every tool declares an output schema"
    [ "describe"; "eval"; "load"; "require"; "reset" ] schemas

let test_eval_through_the_loop () =
  with_server @@ fun c ->
  let args code = `Assoc [ "session", `String "s"; "code", `String code ] in
  let r = call c ~id:1 ~tool:"eval" ~args:(args "let x = 6 * 7;;") in
  Alcotest.(check bool) "a binding renders" true (has "val x : int = 42" (text r));
  Alcotest.(check bool) "and is not an error" false (is_error r);
  let r = call c ~id:2 ~tool:"eval" ~args:(args "x + 1;;") in
  Alcotest.(check bool) "state persists across calls" true (has "43" (text r))

(* A failed phrase is a successful call: isError means the server failed at its
   own job, not that the code was wrong. *)
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
  Alcotest.(check bool) "the session still works" false (is_error r)

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
  Alcotest.(check bool) "and does not claim packages were lost" false
    (has "restarted" (text r));
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

let () =
  Alcotest.run "utop-mcp-server"
    [ ("mcp",
       [ Alcotest.test_case "both handshakes" `Slow test_handshake;
         Alcotest.test_case "initialize agrees on the client version" `Slow
           test_initialize_agrees_on_the_client_version;
         Alcotest.test_case "tools listed" `Slow test_tools_listed ]);
      ("tools",
       [ Alcotest.test_case "eval through the loop" `Slow test_eval_through_the_loop;
         Alcotest.test_case "type error is not isError" `Slow
           test_type_error_is_not_is_error;
         Alcotest.test_case "unknown tool is isError" `Slow
           test_unknown_tool_is_is_error;
         Alcotest.test_case "sessions are independent" `Slow
           test_sessions_are_independent;
         Alcotest.test_case "a stuck session does not block the server" `Slow
           test_a_stuck_session_does_not_block_the_server;
         Alcotest.test_case "answers before exiting on eof" `Slow
           test_answers_before_exiting_on_eof ]);
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
      ("sessions",
       [ Alcotest.test_case "worker death restarts the name" `Slow
           test_worker_death_restarts_the_name;
         Alcotest.test_case "reset" `Slow test_reset ]) ]
