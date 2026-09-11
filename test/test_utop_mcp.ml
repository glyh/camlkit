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
  check (Msg.Eval { source = "1 + 1;;"; autorun = None });
  check (Msg.Eval { source = "1;;"; autorun = Some [ "lwt" ] });
  check (Msg.Describe "List");
  check (Msg.Require [ "yojson"; "str" ])

let test_response_roundtrip () =
  let check r =
    Alcotest.(check string) "response survives"
      (Yojson.Safe.to_string (Msg.json_of_response r))
      (Yojson.Safe.to_string
         (Msg.json_of_response (Msg.response_of_json (Msg.json_of_response r))))
  in
  check (Msg.Completed
           { phrases = [ { rendering = "val x : int = 42"; warnings = "";
                           out_start = 0; out_len = 0; truncated = false;
                           bindings = [ { bound = "x"; bound_type = "int" } ];
                           ran = None } ];
             autorun = None });
  check (Msg.Completed
           { phrases = [ { rendering = "- : int = 42"; warnings = "";
                           out_start = 0; out_len = 0; truncated = false;
                           bindings = []; ran = Some "lwt" } ];
             autorun = Some [ "lwt"; "async" ] });
  check (Msg.Failed { phase = Msg.Typecheck; phrase_index = 1;
                      message = "Error: ..."; spans = [ (4, 8) ];
                      lines = [ (1, 1) ]; done_ = [] });
  check (Msg.Rejected "directives not accepted");
  check (Msg.Loaded { loaded = [ "a"; "b" ]; failed = [ ("c", "boom") ] });
  check (Msg.Loaded { loaded = []; failed = [] })

(* Output is capped because an MCP result is one payload with no streaming.
   Clamping is pure, so this needs no toplevel. *)
let test_clamp () =
  let p start len =
    Msg.{ rendering = ""; warnings = ""; out_start = start; out_len = len;
          truncated = false; bindings = []; ran = None } in
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

(* Most tests only care about the source, so name the common shape. *)
let ev ?autorun source = Msg.Eval { source; autorun }

let has_substring needle hay =
  let re = Str.regexp_string needle in
  try ignore (Str.search_forward re hay 0); true with Not_found -> false

let phrases = function
  | Msg.Completed { phrases = ps; _ } -> ps
  | Msg.Failed f -> Alcotest.failf "expected success, got failure: %s" f.Msg.message
  | Msg.Rejected r -> Alcotest.failf "expected success, got rejection: %s" r
  | Msg.Interrupted _ -> Alcotest.fail "expected success, got interrupt"
  | Msg.Loaded _ -> Alcotest.fail "expected phrase results, got a load result"

let test_eval_and_state () =
  with_worker @@ fun s ->
  let r, _ = ask s (ev "let x = 6 * 7;;") in
  let p = List.hd (phrases r) in
  Alcotest.(check bool) "renders the binding" true
    (String.length p.Msg.rendering > 0);
  let r, _ = ask s (ev "x + 1;;") in
  Alcotest.(check bool) "state persists across calls" true
    (phrases r <> [])

let test_output_is_separate_from_rendering () =
  with_worker @@ fun s ->
  let r, output = ask s (ev "let () = print_string \"printed\";;") in
  let p = List.hd (phrases r) in
  Alcotest.(check string) "program output lands in the raw segment"
    "printed" (String.sub output p.Msg.out_start p.Msg.out_len);
  Alcotest.(check bool) "and not in the rendering" false
    (p.Msg.rendering = "printed")

let test_type_error_executes_nothing () =
  with_worker @@ fun s ->
  let r, _ = ask s (ev "let survivor = 1;; survivor + true;;") in
  (match r with
   | Msg.Failed f -> Alcotest.(check string) "failed at typecheck"
                       "typecheck" (Msg.string_of_phase f.Msg.phase)
   | _ -> Alcotest.fail "expected a typecheck failure");
  (* the first phrase must not have run *)
  let r, _ = ask s (ev "survivor;;") in
  match r with
  | Msg.Failed _ -> ()
  | _ -> Alcotest.fail "the earlier phrase ran despite a later type error"

let test_directives_rejected () =
  with_worker @@ fun s ->
  let r, _ = ask s (ev "#require \"str\";;") in
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
  let r, _ = ask s (ev "1 + 41;;") in
  Alcotest.(check bool) "a bare expression is bound, not just printed" true
    (has_substring "val _0 : int = 42" (render r));
  let r, _ = ask s (ev "\"hello\";;") in
  Alcotest.(check bool) "numbering advances across calls, not just within one"
    true (has_substring "val _1" (render r));
  let r, _ = ask s (ev "true;; 3.5;;") in
  (match phrases r with
   | [ a; b ] ->
     Alcotest.(check bool) "and within a call" true
       (has_substring "val _2" a.Msg.rendering && has_substring "val _3" b.Msg.rendering)
   | _ -> Alcotest.fail "expected two phrase records");
  let r, _ = ask s (ev "_0 + 1;;") in
  Alcotest.(check bool) "earlier results stay referenceable" true
    (has_substring "= 43" (render r))

(* #require and UTop.require both swallow findlib errors into printed text, so
   a missing package used to come back as success. *)
let test_require () =
  with_worker @@ fun s ->
  let r, _ = ask s (Msg.Require [ "str" ]) in
  (match r with
   | Msg.Loaded { loaded; failed } ->
     Alcotest.(check (list string)) "names what it loaded" [ "str" ] loaded;
     Alcotest.(check int) "and nothing failed" 0 (List.length failed)
   | _ -> Alcotest.fail "expected a load result");
  let r, _ = ask s (ev "Str.regexp;;") in
  Alcotest.(check bool) "a required package becomes usable" true (phrases r <> []);
  let r, _ = ask s (Msg.Require [ "no-such-package-xyz" ]) in
  match r with
  | Msg.Loaded { loaded; failed } ->
    Alcotest.(check (list string)) "nothing is claimed as loaded" [] loaded;
    Alcotest.(check bool) "and the failure names the package" true
      (List.exists
         (fun (pkg, err) ->
            pkg = "no-such-package-xyz" && has_substring "no such package" err)
         failed)
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
       let r, _ = ask s (ev "injected_by_user_init;;") in
       match r with
       | Msg.Failed _ -> ()
       | _ -> Alcotest.fail "the user's init.ml leaked into a session")

(* Locations come straight off Location.error_of_exn now, rather than by
   scanning a rendering, but Location still keeps cross-request state that can
   shift things, so both the first error and a later one are pinned. *)
let test_error_locations () =
  with_worker @@ fun s ->
  let fail_of r = match r with
    | Msg.Failed f -> f
    | _ -> Alcotest.fail "expected a typecheck failure" in
  let r, _ = ask s (ev "let a = 1;; a + true;;") in
  let f = fail_of r in
  Alcotest.(check (list (pair int int))) "byte offsets point at the bad token"
    [ (16, 20) ] f.Msg.spans;
  Alcotest.(check (list (pair int int))) "and the line range is there"
    [ (1, 1) ] f.Msg.lines;
  Alcotest.(check bool) "the message has no location prefix, since it is structured"
    false (has_substring "characters" f.Msg.message);
  (* the regression: a second error in the same worker *)
  let r, _ = ask s (ev "nonexistent_value;;") in
  let g = fail_of r in
  Alcotest.(check (list (pair int int))) "a later error still locates correctly"
    [ (0, 17) ] g.Msg.spans;
  Alcotest.(check (list (pair int int))) "later line ranges too" [ (1, 1) ] g.Msg.lines

(* The transcript is still the display half, and the names and types a phrase
   bound are carried as data beside it. What was removed and stays removed: a
   kind that could only say "bindings" or "nothing", and a value that
   duplicated the rendering. *)
let test_bindings_carry_names_and_types () =
  with_worker @@ fun s ->
  let bindings code =
    let r, _ = ask s (ev code) in (List.hd (phrases r)).Msg.bindings in
  (match bindings "let n = 41;;" with
   | [ b ] ->
     Alcotest.(check string) "name" "n" b.Msg.bound;
     Alcotest.(check string) "type, unparsed" "int" b.Msg.bound_type
   | _ -> Alcotest.fail "expected one binding");
  (match bindings "let g x y = x +. y;;" with
   | [ b ] ->
     Alcotest.(check string) "a function's type" "float -> float -> float"
       b.Msg.bound_type
   | _ -> Alcotest.fail "expected one binding");
  (match bindings "let a = 1 and b = \"two\";;" with
   | [ x; y ] ->
     Alcotest.(check (list string)) "several at once" [ "a"; "b" ]
       [ x.Msg.bound; y.Msg.bound ]
   | _ -> Alcotest.fail "expected two bindings");
  (match bindings "module M : sig val z : int end = struct let z = 1 end;;" with
   | [ b ] ->
     Alcotest.(check string) "a module is named" "M" b.Msg.bound;
     Alcotest.(check bool) "and its signature is the type" true
       (has_substring "val z : int" b.Msg.bound_type)
   | _ -> Alcotest.fail "expected one binding");
  Alcotest.(check (list string)) "a phrase that binds nothing" []
    (List.map (fun b -> b.Msg.bound) (bindings "let () = print_string \"q\";;"))

let test_rendering_carries_the_transcript () =
  with_worker @@ fun s ->
  let rendering code =
    let r, _ = ask s (ev code) in (List.hd (phrases r)).Msg.rendering in
  Alcotest.(check bool) "a binding, with its type and value" true
    (has_substring "val _0 : int = 42" (rendering "1 + 41;;"));
  Alcotest.(check bool) "a function's type" true
    (has_substring "int -> int -> int" (rendering "let g x y = x + y;;"));
  Alcotest.(check bool) "a type declaration" true
    (has_substring "type colour = Red | Blue" (rendering "type colour = Red | Blue;;"));
  Alcotest.(check string) "and a phrase that produced nothing renders nothing"
    "" (rendering "let () = print_string \"quiet\";;")

(* Incomplete input used to kill the worker outright: utop raised Need_more to
   ask a line editor for more, and nothing here can prompt, so it escaped. It
   is a syntax error like any other. *)
let test_incomplete_input_is_an_error_not_a_crash () =
  with_worker @@ fun s ->
  List.iter
    (fun src ->
       let r, _ = ask s (ev src) in
       match r with
       | Msg.Failed f ->
         Alcotest.(check string) "rejected while parsing" "parse"
           (Msg.string_of_phase f.Msg.phase)
       | _ -> Alcotest.failf "expected a parse failure for %S" src)
    [ "let x = "; "let x = (1 +"; "match x with" ];
  (* and the session is still alive *)
  let r, _ = ask s (ev "1 + 1;;") in
  Alcotest.(check bool) "the session survives" true (phrases r <> [])

(* An Lwt expression at a toplevel otherwise yields a promise nobody ran.
   Rewritten to run, as utop does. The rule self-gates on the type and on the
   runner existing, so a session that never loads Lwt is unaffected. *)
let test_lwt_expressions_run () =
  with_worker @@ fun s ->
  (match ask s (Msg.Require [ "lwt.unix" ]) with
   | Msg.Loaded { failed = []; _ }, _ -> ()
   | _ -> Alcotest.fail "lwt.unix is needed for this test");
  let render code =
    let r, _ = ask s (ev code) in (List.hd (phrases r)).Msg.rendering in
  let typ ?autorun code =
    let r, _ = ask s (ev ?autorun code) in
    (List.hd (List.hd (phrases r)).Msg.bindings).Msg.bound_type
  in
  Alcotest.(check string) "a promise is run, not returned" "int"
    (typ "Lwt.return 42;;");
  Alcotest.(check bool) "and its value is the result" true
    (has_substring "= 42" (render "Lwt.return 42;;"));
  Alcotest.(check string) "it really waits" "string"
    (typ "Lwt.bind (Lwt_unix.sleep 0.02) (fun () -> Lwt.return \"slept\");;");
  (* Only a bare expression is rewritten. A let keeps the promise, which is
     what someone binding it intended. *)
  Alcotest.(check bool) "a let binding keeps its promise" true
    (has_substring "Lwt.t" (render "let p = Lwt.return 7;;"));
  (* and ordinary code is untouched *)
  Alcotest.(check string) "nothing else changes" "int" (typ "40 + 2;;");
  (* the caller can ask for the promise itself *)
  (match ask s (ev ~autorun:[] "Lwt.return 42;;") with
   | Msg.Completed { phrases = [ p ]; autorun }, _ ->
     Alcotest.(check bool) "an empty list returns the promise" true
       (has_substring "Lwt.t" p.Msg.rendering);
     Alcotest.(check bool) "and the result says rewriting is off" true
       (autorun = Some []);
     Alcotest.(check bool) "with no rule credited for the phrase" true
       (p.Msg.ran = None)
   | _ -> Alcotest.fail "expected a completed phrase");
  (* naming only async leaves lwt alone *)
  (match ask s (ev ~autorun:[ "async" ] "Lwt.return 42;;") with
   | Msg.Completed { phrases = [ p ]; autorun }, _ ->
     Alcotest.(check bool) "async only does not run lwt" true
       (has_substring "Lwt.t" p.Msg.rendering);
     Alcotest.(check bool) "and the setting is reported back" true
       (autorun = Some [ "async" ])
   | _ -> Alcotest.fail "expected a completed phrase");
  (* and turning it back on works *)
  Alcotest.(check string) "re-enabling runs it again" "int"
    (typ ~autorun:[ "lwt" ] "Lwt.return 42;;");
  (* a rewritten phrase says which rule rewrote it, and the setting is sticky
     across calls that do not mention it *)
  (match ask s (ev "Lwt.return 42;;") with
   | Msg.Completed { phrases = [ p ]; autorun }, _ ->
     Alcotest.(check bool) "the phrase credits the rule that ran it" true
       (p.Msg.ran = Some "lwt");
     Alcotest.(check bool) "and the setting persisted without being repeated"
       true (autorun = Some [ "lwt" ])
   | _ -> Alcotest.fail "expected a completed phrase");
  (* ordinary code credits nothing *)
  (match ask s (ev "40 + 2;;") with
   | Msg.Completed { phrases = [ p ]; _ }, _ ->
     Alcotest.(check bool) "a plain expression was not rewritten" true
       (p.Msg.ran = None)
   | _ -> Alcotest.fail "expected a completed phrase");
  (* an unknown rule is refused rather than ignored, and leaves the previous
     setting standing rather than clearing it *)
  (match ask s (ev ~autorun:[ "nonsense" ] "1;;") with
   | Msg.Failed f, _ ->
     Alcotest.(check bool) "and says what it knows" true
       (has_substring "no such autorun rule" f.Msg.message)
   | _ -> Alcotest.fail "an unknown autorun rule should be refused");
  (match ask s (ev "Lwt.return 42;;") with
   | Msg.Completed { autorun; _ }, _ ->
     Alcotest.(check bool) "a refused setting leaves the old one intact" true
       (autorun = Some [ "lwt" ])
   | _ -> Alcotest.fail "expected a completed phrase")

(* Reported from a session driving a real project: loading its code died with
   "Reference to undefined compilation unit Stdlib__Dynarray" even though the
   switch has it. The worker is byte_complete, so the linker drops stdlib units
   nothing in the worker mentions. Fixed with -linkall, which in turn activated
   utop's hide-reserved filter and hid the implicit bindings, so the two are
   tested together. *)
let test_stdlib_is_fully_linked () =
  with_worker @@ fun s ->
  let r, _ = ask s (ev
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
      (ev "let () = print_string \"ran-first\";; \
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

(* Reported as output being capped too generously; the real defect was that
   Unix.read copies through a fixed 64K buffer, so a single read silently lost
   everything past 65536 bytes while reporting no truncation at all. *)
let test_large_output_is_capped_honestly () =
  with_worker @@ fun s ->
  let r, output = ask s
      (ev "let () = print_string (String.make 500_000 'x');;") in
  let p = List.hd (phrases r) in
  Alcotest.(check int) "capped at the limit, not at Unix.read's buffer"
    Msg.output_limit (String.length output);
  Alcotest.(check int) "and the span matches what was sent"
    Msg.output_limit p.Msg.out_len;
  Alcotest.(check bool) "truncation is reported" true p.Msg.truncated

(* The flag has to be honest in both directions, or it is worse than useless. *)
let test_small_output_is_not_marked_truncated () =
  with_worker @@ fun s ->
  let r, _ = ask s (ev "let () = print_string \"small\";; 1 + 1;;") in
  List.iter
    (fun p -> Alcotest.(check bool) "not truncated" false p.Msg.truncated)
    (phrases r)

(* Output that is merely long, rather than enormous, must survive intact:
   the 64K bug was invisible until something printed more than that. *)
let test_output_between_64k_and_the_cap () =
  with_worker @@ fun s ->
  let r, output = ask s
      (ev "let () = print_string (String.make 12_000 'y');;") in
  let p = List.hd (phrases r) in
  Alcotest.(check int) "nothing is lost below the cap" 12_000 p.Msg.out_len;
  Alcotest.(check bool) "and it is not marked truncated" false p.Msg.truncated;
  Alcotest.(check int) "payload carries it all" 12_000 (String.length output)

(* Reported as a sharp edge rather than a bug: because nothing runs unless
   every phrase typechecks, a phrase that changes the search path cannot be
   used by a later phrase in the same call. Worth pinning so the behaviour is
   deliberate rather than accidental. *)
let test_path_changes_need_their_own_call () =
  with_worker @@ fun s ->
  let r, _ = ask s (ev
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
           (ev "let () = print_string \"printed-before-hanging\";\n\
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
  let r, _ = ask s (ev "1 + 1;;") in
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
         Alcotest.test_case "rendering carries the transcript" `Slow
           test_rendering_carries_the_transcript;
         Alcotest.test_case "bindings carry names and types" `Slow
           test_bindings_carry_names_and_types;
         Alcotest.test_case "lwt expressions run" `Slow test_lwt_expressions_run;
         Alcotest.test_case "incomplete input is an error not a crash" `Slow
           test_incomplete_input_is_an_error_not_a_crash;
         Alcotest.test_case "stdlib is fully linked" `Slow
           test_stdlib_is_fully_linked;
         Alcotest.test_case "output survives a later failure" `Slow
           test_output_survives_a_later_failure;
         Alcotest.test_case "path changes need their own call" `Slow
           test_path_changes_need_their_own_call;
         Alcotest.test_case "large output is capped honestly" `Slow
           test_large_output_is_capped_honestly;
         Alcotest.test_case "small output is not marked truncated" `Slow
           test_small_output_is_not_marked_truncated;
         Alcotest.test_case "output between 64k and the cap" `Slow
           test_output_between_64k_and_the_cap;
         Alcotest.test_case "partial output recovered on interrupt" `Slow
           test_partial_output_recovered_on_interrupt ]) ]
