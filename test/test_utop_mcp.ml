open Wire
open Utop_mcp

(* --- framing: pure, so no channels, pipes or temp files ---------------- *)

let roundtrip (f : Frame.t) =
  match Frame.parse (Frame.encode f) with
  | Frame.Complete (g, n) -> (g, n)
  | Frame.Need n -> Alcotest.failf "encode produced a short frame, wants %d more" n
  | Frame.Malformed m -> Alcotest.fail m

let test_frame_roundtrip () =
  let f = Frame.{ meta = `Assoc [ "kind", `String "eval" ];
                  payload = "line one\nline two\n\000binary\xff" } in
  let g, n = roundtrip f in
  Alcotest.(check string) "payload is byte-identical, newlines and all"
    f.Frame.payload g.Frame.payload;
  Alcotest.(check string) "metadata survives"
    (Yojson.Safe.to_string f.Frame.meta) (Yojson.Safe.to_string g.Frame.meta);
  Alcotest.(check int) "consumes exactly the frame"
    (String.length (Frame.encode f)) n

let test_frame_empty_payload () =
  let g, _ = roundtrip Frame.{ meta = `Assoc []; payload = "" } in
  Alcotest.(check string) "empty payload" "" g.Frame.payload

(* A reader is fed a stream, not a frame, so partial input must ask for more
   rather than fail. *)
let test_frame_partial () =
  let whole = Frame.encode Frame.{ meta = `Assoc [ "k", `String "v" ];
                                   payload = "abcdef" } in
  let asks_for_more k =
    match Frame.parse (String.sub whole 0 k) with
    | Frame.Need n -> Alcotest.(check bool) "wants a positive amount" true (n > 0)
    | Frame.Complete _ -> Alcotest.failf "claimed complete after only %d bytes" k
    | Frame.Malformed m -> Alcotest.fail m
  in
  List.iter asks_for_more [ 0; 1; 3; 4; 6; String.length whole - 1 ]

let test_frame_trailing_bytes () =
  let f = Frame.{ meta = `Assoc []; payload = "x" } in
  let stream = Frame.encode f ^ "leftovers" in
  match Frame.parse stream with
  | Frame.Complete (_, n) ->
    Alcotest.(check int) "stops at the frame boundary"
      (String.length (Frame.encode f)) n
  | _ -> Alcotest.fail "a complete frame followed by more bytes should parse"

(* --- message encoding --------------------------------------------------- *)

let test_request_roundtrip () =
  let check r =
    Alcotest.(check string) "request survives"
      (Yojson.Safe.to_string (Msg.json_of_request r))
      (Yojson.Safe.to_string
         (Msg.json_of_request (Msg.request_of_json (Msg.json_of_request r))))
  in
  check (Msg.Eval "1 + 1;;");
  check (Msg.Describe "List");
  check (Msg.Require [ "yojson"; "str" ])

let test_response_roundtrip () =
  let check r =
    Alcotest.(check string) "response survives"
      (Yojson.Safe.to_string (Msg.json_of_response r))
      (Yojson.Safe.to_string
         (Msg.json_of_response (Msg.response_of_json (Msg.json_of_response r))))
  in
  check (Msg.Completed [ { rendering = "val x : int = 42"; warnings = "";
                           out_start = 0; out_len = 0 } ]);
  check (Msg.Failed { phase = Msg.Typecheck; phrase_index = 1;
                      message = "Error: ..."; spans = [ (4, 8) ] });
  check (Msg.Rejected "directives not accepted")

(* --- supervision: pure, so no processes and no waiting ----------------- *)

let test_escalation () =
  let open Supervision in
  let s = Idle in
  let s, a = step s (Sent { now = 0.0; timeout = 10.0 }) in
  Alcotest.(check bool) "sending arms a deadline" true (deadline s = Some 10.0);
  Alcotest.(check bool) "and does nothing yet" true (a = Nothing);
  let s, a = step s (Expired { now = 10.0; grace = 2.0 }) in
  Alcotest.(check bool) "first expiry interrupts rather than killing" true
    (a = Interrupt);
  Alcotest.(check bool) "and grants a grace period" true (deadline s = Some 12.0);
  let _, a = step s (Expired { now = 12.0; grace = 2.0 }) in
  Alcotest.(check bool) "second expiry kills" true
    (match a with Reap _ -> true | _ -> false)

let test_interrupt_answered_keeps_session () =
  let open Supervision in
  let s, _ = step Idle (Sent { now = 0.0; timeout = 5.0 }) in
  let s, _ = step s (Expired { now = 5.0; grace = 2.0 }) in
  let s, a = step s Replied in
  Alcotest.(check bool) "answering the interrupt returns to idle" true (s = Idle);
  Alcotest.(check bool) "and kills nothing" true (a = Nothing);
  Alcotest.(check bool) "so the session is usable again" true
    (may_send s = Ok ())

let test_concurrent_send_refused () =
  let open Supervision in
  let s, _ = step Idle (Sent { now = 0.0; timeout = 5.0 }) in
  Alcotest.(check bool) "a busy session refuses a second evaluation" true
    (Result.is_error (may_send s));
  let s, _ = step s (Vanished "crash") in
  Alcotest.(check bool) "a dead session refuses too" true
    (Result.is_error (may_send s))

let test_dead_is_terminal () =
  let open Supervision in
  let s, _ = step Idle (Vanished "segfault") in
  let s', a = step s (Sent { now = 0.0; timeout = 5.0 }) in
  Alcotest.(check bool) "death absorbs later events" true (s' = s && a = Nothing)

(* --- against a real worker ---------------------------------------------- *)

let with_worker f =
  Unix.putenv "UTOP_MCP_WORKER" "../worker/main.bc.exe";
  let s = Session.spawn "test" in
  Fun.protect ~finally:(fun () -> Session.kill s "test over")
    (fun () ->
       (match Session.read_greeting s with
        | Ok () -> () | Error e -> Alcotest.fail e);
       f s)

let ask s request =
  match Session.send s request ~timeout:30.0 with
  | Error e -> Alcotest.fail e
  | Ok () ->
    (match Session.receive s with
     | Error e -> Alcotest.fail e
     | Ok (response, output) -> (response, output))

let phrases = function
  | Msg.Completed ps -> ps
  | Msg.Failed f -> Alcotest.failf "expected success, got failure: %s" f.Msg.message
  | Msg.Rejected r -> Alcotest.failf "expected success, got rejection: %s" r
  | Msg.Interrupted _ -> Alcotest.fail "expected success, got interrupt"

let test_eval_and_state () =
  with_worker @@ fun s ->
  let r, _ = ask s (Msg.Eval "let x = 6 * 7;;") in
  let p = List.hd (phrases r) in
  Alcotest.(check bool) "renders the binding" true
    (String.length p.Msg.rendering > 0);
  let r, _ = ask s (Msg.Eval "x + 1;;") in
  Alcotest.(check bool) "state persists across calls" true
    (phrases r <> [])

let test_output_is_separate_from_rendering () =
  with_worker @@ fun s ->
  let r, output = ask s (Msg.Eval "let () = print_string \"printed\";;") in
  let p = List.hd (phrases r) in
  Alcotest.(check string) "program output lands in the raw segment"
    "printed" (String.sub output p.Msg.out_start p.Msg.out_len);
  Alcotest.(check bool) "and not in the rendering" false
    (p.Msg.rendering = "printed")

let test_type_error_executes_nothing () =
  with_worker @@ fun s ->
  let r, _ = ask s (Msg.Eval "let survivor = 1;; survivor + true;;") in
  (match r with
   | Msg.Failed f -> Alcotest.(check string) "failed at typecheck"
                       "typecheck" (Msg.string_of_phase f.Msg.phase)
   | _ -> Alcotest.fail "expected a typecheck failure");
  (* the first phrase must not have run *)
  let r, _ = ask s (Msg.Eval "survivor;;") in
  match r with
  | Msg.Failed _ -> ()
  | _ -> Alcotest.fail "the earlier phrase ran despite a later type error"

let test_directives_rejected () =
  with_worker @@ fun s ->
  let r, _ = ask s (Msg.Eval "#require \"str\";;") in
  match r with
  | Msg.Rejected _ -> ()
  | _ -> Alcotest.fail "eval accepted a directive"

(* Directives print to stdout rather than to the formatter passed to
   execute_phrase, so a describe answer arrives in the raw segment with an
   empty rendering. *)
let test_describe () =
  with_worker @@ fun s ->
  let r, output = ask s (Msg.Describe "Option") in
  let p = List.hd (phrases r) in
  Alcotest.(check string) "rendering is empty for a directive" "" p.Msg.rendering;
  let sign = String.sub output p.Msg.out_start p.Msg.out_len in
  let has needle =
    let re = Str.regexp_string needle in
    try ignore (Str.search_forward re sign 0); true with Not_found -> false
  in
  Alcotest.(check bool) "signature names the module" true (has "module Option");
  Alcotest.(check bool) "and carries types" true
    (has "val value : \'a t -> default:\'a -> \'a")

let () =
  Alcotest.run "utop-mcp"
    [ ("frame",
       [ Alcotest.test_case "roundtrip" `Quick test_frame_roundtrip;
         Alcotest.test_case "empty payload" `Quick test_frame_empty_payload;
         Alcotest.test_case "partial input" `Quick test_frame_partial;
         Alcotest.test_case "trailing bytes" `Quick test_frame_trailing_bytes ]);
      ("msg",
       [ Alcotest.test_case "request" `Quick test_request_roundtrip;
         Alcotest.test_case "response" `Quick test_response_roundtrip ]);
      ("supervision",
       [ Alcotest.test_case "escalation" `Quick test_escalation;
         Alcotest.test_case "interrupt answered" `Quick
           test_interrupt_answered_keeps_session;
         Alcotest.test_case "concurrent send refused" `Quick
           test_concurrent_send_refused;
         Alcotest.test_case "dead is terminal" `Quick test_dead_is_terminal ]);
      ("worker",
       [ Alcotest.test_case "eval and state" `Slow test_eval_and_state;
         Alcotest.test_case "output vs rendering" `Slow
           test_output_is_separate_from_rendering;
         Alcotest.test_case "type error executes nothing" `Slow
           test_type_error_executes_nothing;
         Alcotest.test_case "directives rejected" `Slow test_directives_rejected;
         Alcotest.test_case "describe" `Slow test_describe ]) ]
