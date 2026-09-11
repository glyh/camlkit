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
                           out_start = 0; out_len = 0; truncated = false } ]);
  check (Msg.Failed { phase = Msg.Typecheck; phrase_index = 1;
                      message = "Error: ..."; spans = [ (4, 8) ];
                      lines = [ (1, 1) ]; done_ = [] });
  check (Msg.Rejected "directives not accepted")

(* Output is capped because an MCP result is one payload with no streaming.
   Clamping is pure, so this needs no toplevel. *)
let test_clamp () =
  let p start len =
    Msg.{ rendering = ""; warnings = ""; out_start = start; out_len = len;
          truncated = false } in
  let ps, any = Msg.clamp ~limit:100 [ p 0 50; p 50 50 ] in
  Alcotest.(check bool) "nothing under the limit is touched" false any;
  Alcotest.(check bool) "spans unchanged" true
    (List.for_all (fun q -> not q.Msg.truncated) ps);
  let ps, any = Msg.clamp ~limit:100 [ p 0 50; p 50 80; p 130 20 ] in
  Alcotest.(check bool) "crossing the limit is reported" true any;
  match ps with
  | [ a; b; c ] ->
    Alcotest.(check bool) "the phrase below the limit is intact" false a.Msg.truncated;
    Alcotest.(check int) "the straddling phrase is cut at the limit" 50 b.Msg.out_len;
    Alcotest.(check bool) "and marked" true b.Msg.truncated;
    Alcotest.(check int) "one entirely past the limit reads nothing" 0 c.Msg.out_len;
    Alcotest.(check bool) "no span reaches past the payload" true
      (List.for_all (fun q -> q.Msg.out_start + q.Msg.out_len <= 100) ps)
  | _ -> Alcotest.fail "expected three records"

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
  Fun.protect ~finally:(fun () -> Session.dispose s) (fun () -> f s)

let ask s request =
  match Session.send s request ~timeout:30.0 with
  | Error e -> Alcotest.fail e
  | Ok () ->
    (match Session.receive s with
     | Error e -> Alcotest.fail e
     | Ok (response, output) -> (response, output))

let has_substring needle hay =
  let re = Str.regexp_string needle in
  try ignore (Str.search_forward re hay 0); true with Not_found -> false

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
  Alcotest.(check bool) "signature names the module" true
    (has_substring "module Option" sign);
  Alcotest.(check bool) "and carries types" true
    (has_substring "val value : \'a t -> default:\'a -> \'a" sign)

(* UTop.set_create_implicits only sets a flag read by UTop_main.bind_expressions,
   which is not exported, so the rewrite is ours and needs its own cover. *)
let test_implicit_bindings () =
  with_worker @@ fun s ->
  let render r = (List.hd (phrases r)).Msg.rendering in
  let r, _ = ask s (Msg.Eval "1 + 41;;") in
  Alcotest.(check bool) "a bare expression is bound, not just printed" true
    (has_substring "val _0 : int = 42" (render r));
  let r, _ = ask s (Msg.Eval "\"hello\";;") in
  Alcotest.(check bool) "numbering advances across calls, not just within one"
    true (has_substring "val _1" (render r));
  let r, _ = ask s (Msg.Eval "true;; 3.5;;") in
  (match phrases r with
   | [ a; b ] ->
     Alcotest.(check bool) "and within a call" true
       (has_substring "val _2" a.Msg.rendering && has_substring "val _3" b.Msg.rendering)
   | _ -> Alcotest.fail "expected two phrase records");
  let r, _ = ask s (Msg.Eval "_0 + 1;;") in
  Alcotest.(check bool) "earlier results stay referenceable" true
    (has_substring "= 43" (render r))

(* #require and UTop.require both swallow findlib errors into printed text, so
   a missing package used to come back as success. *)
let test_require () =
  with_worker @@ fun s ->
  let r, _ = ask s (Msg.Require [ "str" ]) in
  ignore (phrases r);
  let r, _ = ask s (Msg.Eval "Str.regexp;;") in
  Alcotest.(check bool) "a required package becomes usable" true (phrases r <> []);
  let r, _ = ask s (Msg.Require [ "no-such-package-xyz" ]) in
  match r with
  | Msg.Failed f ->
    Alcotest.(check bool) "a missing package fails rather than reporting success"
      true (has_substring "no such package" f.Msg.message)
  | _ -> Alcotest.fail "a missing package was reported as success"

(* The hermetic guarantee used to come from -init /dev/null on the utop binary.
   Linking removed the flag, so it now rests on never calling the init-file
   path at all, which is worth pinning down. *)
let test_hermetic () =
  let dir = Filename.temp_dir "utop-mcp-cfg" "" in
  Unix.mkdir (Filename.concat dir "utop") 0o700;
  let oc = open_out (Filename.concat dir "utop/init.ml") in
  output_string oc "let injected_by_user_init = 1\n"; close_out oc;
  Unix.putenv "XDG_CONFIG_HOME" dir;
  Fun.protect
    ~finally:(fun () -> Unix.putenv "XDG_CONFIG_HOME" "")
    (fun () ->
       with_worker @@ fun s ->
       let r, _ = ask s (Msg.Eval "injected_by_user_init;;") in
       match r with
       | Msg.Failed _ -> ()
       | _ -> Alcotest.fail "the user's init.ml leaked into a session")

(* get_ocaml_error_message recovers locations by scanning its own rendering,
   and Location keeps cross-request state that shifts that text. Both halves
   regressed once, so both are pinned: the first error, and a later one in the
   same session. *)
let test_error_locations () =
  with_worker @@ fun s ->
  let fail_of r = match r with
    | Msg.Failed f -> f
    | _ -> Alcotest.fail "expected a typecheck failure" in
  let r, _ = ask s (Msg.Eval "let a = 1;; a + true;;") in
  let f = fail_of r in
  Alcotest.(check (list (pair int int))) "byte offsets point at the bad token"
    [ (16, 20) ] f.Msg.spans;
  Alcotest.(check (list (pair int int))) "and the line range is there"
    [ (1, 1) ] f.Msg.lines;
  Alcotest.(check bool) "the message has no location prefix, since it is structured"
    false (has_substring "characters" f.Msg.message);
  (* the regression: a second error in the same worker *)
  let r, _ = ask s (Msg.Eval "nonexistent_value;;") in
  let g = fail_of r in
  Alcotest.(check (list (pair int int))) "a later error still locates correctly"
    [ (0, 17) ] g.Msg.spans;
  Alcotest.(check (list (pair int int))) "later line ranges too" [ (1, 1) ] g.Msg.lines

(* Reported from a session driving a real project: loading its code died with
   "Reference to undefined compilation unit Stdlib__Dynarray" even though the
   switch has it. The worker is byte_complete, so the linker drops stdlib units
   nothing in the worker mentions. Fixed with -linkall, which in turn activated
   utop's hide-reserved filter and hid the implicit bindings, so the two are
   tested together. *)
let test_stdlib_is_fully_linked () =
  with_worker @@ fun s ->
  let r, _ = ask s (Msg.Eval
      "let d : int Dynarray.t = Dynarray.create () in \
       Dynarray.add_last d 7; Dynarray.get d 0;;") in
  (match r with
   | Msg.Failed f ->
     Alcotest.failf "a stdlib module was not linked: %s" f.Msg.message
   | _ -> ());
  Alcotest.(check bool) "and the value renders" true
    (has_substring "= 7" (List.hd (phrases r)).Msg.rendering)

(* Reported: three phrases, the second throws, and the first one's output was
   gone even though it ran. A runtime failure is not a rejected request. *)
let test_output_survives_a_later_failure () =
  with_worker @@ fun s ->
  let r, output = ask s
      (Msg.Eval "let () = print_string \"ran-first\";; \
                 failwith \"boom\";; \
                 let () = print_string \"never\";;") in
  match r with
  | Msg.Failed f ->
    Alcotest.(check string) "failed while executing, not before"
      "execute" (Msg.string_of_phase f.Msg.phase);
    Alcotest.(check int) "the phrase that ran is kept" 1 (List.length f.Msg.done_);
    let p = List.hd f.Msg.done_ in
    Alcotest.(check string) "with its output intact"
      "ran-first" (String.sub output p.Msg.out_start p.Msg.out_len);
    Alcotest.(check bool) "and the failing phrase is not duplicated into it"
      false (has_substring "boom" p.Msg.rendering)
  | _ -> Alcotest.fail "expected a runtime failure"

(* Reported as a sharp edge rather than a bug: because nothing runs unless
   every phrase typechecks, a phrase that changes the search path cannot be
   used by a later phrase in the same call. Worth pinning so the behaviour is
   deliberate rather than accidental. *)
let test_path_changes_need_their_own_call () =
  with_worker @@ fun s ->
  let r, _ = ask s (Msg.Eval
      "let () = Topdirs.dir_directory \"/tmp\";; Mylib.make 1;;") in
  match r with
  | Msg.Failed f ->
    Alcotest.(check string) "rejected at typecheck, before anything ran"
      "typecheck" (Msg.string_of_phase f.Msg.phase);
    Alcotest.(check int) "so nothing is reported as having run" 0
      (List.length f.Msg.done_)
  | _ -> Alcotest.fail "expected the whole request to be rejected"

(* The capture file exists so output can be recovered from a phrase that had
   to be interrupted. Worth proving, since OCaml buffers stdout and a hung
   phrase never reaches a flush of its own. *)
let test_partial_output_recovered_on_interrupt () =
  with_worker @@ fun s ->
  (match Session.send s
           (Msg.Eval "let () = print_string \"printed-before-hanging\";\n\
                      let rec spin n = spin (n + 1) in spin 0;;")
           ~timeout:0.5 with
   | Error e -> Alcotest.fail e | Ok () -> ());
  Unix.sleepf 1.0;
  let mid = Session.partial_output s in
  Session.on_deadline s ~grace:2.0;          (* first expiry: interrupt *)
  (match Session.receive s with
   | Error e -> Alcotest.failf "worker did not survive the interrupt: %s" e
   | Ok (r, output) ->
     (match r with
      | Msg.Interrupted _ -> ()
      | _ -> Alcotest.fail "expected an interrupted response");
     Alcotest.(check bool) "output printed before the hang is recovered" true
       (has_substring "printed-before-hanging" output);
     Alcotest.(check bool) "mid-flight read saw nothing, because it was buffered"
       false (has_substring "printed-before-hanging" mid));
  (* and the session is still usable *)
  let r, _ = ask s (Msg.Eval "1 + 1;;") in
  Alcotest.(check bool) "session survives" true (phrases r <> [])

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
      ("output cap", [ Alcotest.test_case "clamp" `Quick test_clamp ]);
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
         Alcotest.test_case "describe" `Slow test_describe;
         Alcotest.test_case "implicit bindings" `Slow test_implicit_bindings;
         Alcotest.test_case "require" `Slow test_require;
         Alcotest.test_case "hermetic" `Slow test_hermetic;
         Alcotest.test_case "error locations" `Slow test_error_locations;
         Alcotest.test_case "stdlib is fully linked" `Slow
           test_stdlib_is_fully_linked;
         Alcotest.test_case "output survives a later failure" `Slow
           test_output_survives_a_later_failure;
         Alcotest.test_case "path changes need their own call" `Slow
           test_path_changes_need_their_own_call;
         Alcotest.test_case "partial output recovered on interrupt" `Slow
           test_partial_output_recovered_on_interrupt ]) ]
