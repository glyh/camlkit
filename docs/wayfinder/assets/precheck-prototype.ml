let say = Printf.printf
let init () =
  Sys.interactive := false; Clflags.real_paths := false;
  Toploop.initialize_toplevel_env ()

(* Pass 1: type every phrase, advancing a working env, evaluating nothing. *)
let precheck phrases =
  let env0 = !Toploop.toplevel_env in
  let restore () = Toploop.toplevel_env := env0 in
  let rec go i = function
    | [] -> restore (); Ok ()
    | Parsetree.Ptop_dir _ :: rest ->
      (* directives are not typeable; utop's own check_phrase skips them too *)
      go (i + 1) rest
    | Parsetree.Ptop_def str :: rest ->
      (match Typemod.type_toplevel_phrase !Toploop.toplevel_env str with
       | (_, _, _, _, env) -> Toploop.toplevel_env := env; go (i + 1) rest
       | exception exn ->
         let _, msg, _ = UTop.get_ocaml_error_message exn in
         restore (); Error (i, msg))
  in
  go 0 phrases

let parse src =
  match !UTop.parse_use_file src false with
  | UTop.Value ps -> ps
  | UTop.Error (_, m) -> failwith ("parse: " ^ m)

let trial name src =
  say "\n--- %s\n    %s\n" name (String.escaped src);
  let ps = parse src in
  match precheck ps with
  | Error (i, msg) ->
    say "    PRECHECK FAILED at phrase %d: %s\n" i
      (String.concat " " (String.split_on_char '\n' msg))
  | Ok () ->
    say "    precheck ok, executing\n";
    List.iter (fun p -> ignore (Toploop.execute_phrase true Format.std_formatter p)) ps

let () =
  init ();
  trial "good sequence, later phrase uses earlier binding" "let a = 5;; a + 1;;";
  trial "type error in phrase 2 - must execute nothing" "let b = 5;; b + true;;";
  say "    is b bound after the failure? ";
  (try ignore (Toploop.execute_phrase true Format.std_formatter
                 (List.hd (parse "b;;"))) with _ -> say "(error)\n");
  trial "directive then dependent, stdlib-adjacent" "#require \"str\";; Str.regexp \"a\";;";
  trial "directive then dependent, real findlib package"
    "#require \"yojson\";; Yojson.Safe.from_string \"[]\";;"
