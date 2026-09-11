open Wire
open Utop_mcp

(* --- framing ------------------------------------------------------------ *)

let roundtrip_frame (f : Frame.t) =
  let path = Filename.temp_file "frame" ".bin" in
  let oc = open_out_bin path in
  Frame.write oc f; close_out oc;
  let ic = open_in_bin path in
  let got = Frame.read ic in
  close_in ic; Sys.remove path;
  got

let test_frame_roundtrip () =
  let f = Frame.{ meta = `Assoc [ "kind", `String "eval" ];
                  payload = "line one\nline two\n\000binary\xff" } in
  match roundtrip_frame f with
  | None -> Alcotest.fail "frame did not survive a round trip"
  | Some g ->
    Alcotest.(check string) "payload is byte-identical, newlines and all"
      f.Frame.payload g.Frame.payload;
    Alcotest.(check string) "metadata survives"
      (Yojson.Safe.to_string f.Frame.meta) (Yojson.Safe.to_string g.Frame.meta)

let test_frame_empty_payload () =
  let f = Frame.{ meta = `Assoc []; payload = "" } in
  match roundtrip_frame f with
  | Some g -> Alcotest.(check string) "empty payload" "" g.Frame.payload
  | None -> Alcotest.fail "empty frame did not survive"

let test_frame_eof () =
  let path = Filename.temp_file "frame" ".bin" in
  let ic = open_in_bin path in
  let got = Frame.read ic in
  close_in ic; Sys.remove path;
  Alcotest.(check bool) "clean EOF reads as None" true (got = None)

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

(* --- against a real worker ---------------------------------------------- *)

let with_worker f =
  Unix.putenv "UTOP_MCP_WORKER" "../worker/main.bc.exe";
  let s = Session.spawn "test" in
  Fun.protect ~finally:(fun () -> Session.kill s "test over") (fun () -> f s)

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
         Alcotest.test_case "clean eof" `Quick test_frame_eof ]);
      ("msg",
       [ Alcotest.test_case "request" `Quick test_request_roundtrip;
         Alcotest.test_case "response" `Quick test_response_roundtrip ]);
      ("worker",
       [ Alcotest.test_case "eval and state" `Slow test_eval_and_state;
         Alcotest.test_case "output vs rendering" `Slow
           test_output_is_separate_from_rendering;
         Alcotest.test_case "type error executes nothing" `Slow
           test_type_error_executes_nothing;
         Alcotest.test_case "directives rejected" `Slow test_directives_rejected;
         Alcotest.test_case "describe" `Slow test_describe ]) ]
