open Utop_mcp

let line = Alcotest.testable
    (fun f (l : Proto.line) -> Format.fprintf f "%s:%s" l.cmd l.arg)
    ( = )

let test_parse () =
  Alcotest.(check (option line)) "splits on first colon"
    (Some { cmd = "accept"; arg = "1,2" }) (Proto.parse "accept:1,2");
  Alcotest.(check (option line)) "empty argument"
    (Some { cmd = "prompt"; arg = "" }) (Proto.parse "prompt:");
  Alcotest.(check (option line)) "argument may contain colons"
    (Some { cmd = "stdout"; arg = "a:b" }) (Proto.parse "stdout:a:b");
  Alcotest.(check (option line)) "no colon is not a line" None (Proto.parse "garbage")

let test_encode_input () =
  Alcotest.(check (list string)) "multi-line phrase becomes one data: per line"
    [ "input:add-to-history"; "data:let x ="; "data:  1;;"; "end:" ]
    (Proto.encode_input ~flags:[ "add-to-history" ] "let x =\n  1;;");
  Alcotest.(check (list string)) "no flags still emits the colon"
    [ "input:"; "data:1;;"; "end:" ] (Proto.encode_input "1;;")

let test_terminate () =
  Alcotest.(check string) "appends missing terminator" "1 + 1;;"
    (Proto.terminate ~terminator:";;" "1 + 1");
  Alcotest.(check string) "leaves an existing one alone" "1 + 1;;"
    (Proto.terminate ~terminator:";;" "1 + 1;;");
  Alcotest.(check string) "trims before deciding" "1 + 1;;"
    (Proto.terminate ~terminator:";;" "  1 + 1;;  ")

let test_sentinel () =
  Alcotest.(check string) "phrase prints exactly the declared marker"
    (Printf.sprintf "let () = Stdlib.print_endline \"%s\";;" (Proto.sentinel_marker 7))
    (Proto.sentinel_phrase 7)

let test_spawn_argv () =
  Alcotest.(check (list string)) "hermetic, via opam exec, implicit bindings"
    [ "opam"; "exec"; "--"; "utop"; "-emacs"; "-init"; "/dev/null";
      "-no-autoload"; "-implicit-bindings" ]
    Proto.spawn_argv

let () =
  Alcotest.run "utop-mcp"
    [ ("proto",
       [ Alcotest.test_case "parse" `Quick test_parse;
         Alcotest.test_case "encode_input" `Quick test_encode_input;
         Alcotest.test_case "terminate" `Quick test_terminate;
         Alcotest.test_case "sentinel" `Quick test_sentinel;
         Alcotest.test_case "spawn_argv" `Quick test_spawn_argv ]) ]
