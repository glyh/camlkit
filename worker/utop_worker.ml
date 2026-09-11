(* Prototype: is the eval loop small enough to own? *)

let capture_path = Filename.temp_file "utop-mcp" ".out"
let capture_fd = Unix.openfile capture_path [ Unix.O_RDWR; Unix.O_CREAT ] 0o600
let capture_off = ref 0

let init () =
  Sys.interactive := false;
  Clflags.real_paths := false;           (* -short-paths *)
  Toploop.initialize_toplevel_env ();
  Unix.dup2 capture_fd Unix.stdout;      (* own the toplevel's stdout outright *)
  Unix.dup2 capture_fd Unix.stderr

(* Read whatever the phrase wrote, from where we last stopped. No race: we
   flush first, and it is a file, so there is no pipe buffer and no copy thread. *)
let drain () =
  flush Stdlib.stdout; flush Stdlib.stderr;
  let len = (Unix.fstat capture_fd).Unix.st_size - !capture_off in
  if len <= 0 then ""
  else begin
    let b = Bytes.create len in
    ignore (Unix.lseek capture_fd !capture_off Unix.SEEK_SET);
    let n = Unix.read capture_fd b 0 len in
    capture_off := !capture_off + n;
    ignore (Unix.lseek capture_fd 0 Unix.SEEK_END);
    Bytes.sub_string b 0 n
  end

type outcome =
  | Value of string                      (* toplevel output *)
  | Error_ of string                     (* parse or type error *)

let eval src =
  match UTop.parse_toplevel_phrase_default src true with
  | UTop.Error (_locs, msg) -> Error_ msg
  | UTop.Value phrase ->
    match UTop.check_phrase phrase with
    | Some (_locs, msg, _) -> Error_ msg
    | None ->
      let buf = Buffer.create 256 in
      let ppf = Format.formatter_of_buffer buf in
      (try ignore (Toploop.execute_phrase true ppf phrase)
       with exn -> Buffer.add_string buf (UTop.get_message Errors.report_error exn));
      Format.pp_print_flush ppf ();
      Value (drain () ^ Buffer.contents buf)

let real = Unix.out_channel_of_descr (Unix.dup Unix.stdout)
let say s = output_string real s; output_char real '\n'; flush real

let () =
  init ();
  let show label src =
    say ("--- " ^ label ^ ": " ^ String.escaped src);
    match eval src with
    | Value s -> say ("OK  " ^ String.escaped s)
    | Error_ s -> say ("ERR " ^ String.escaped s)
  in
  show "binding" "let x = 6 * 7;;";
  show "side effect then value" "let () = print_endline \"side\"; print_endline \"effect\";; ";
  show "uses earlier binding" "x + 1;;";
  show "type error" "1 + true;;";
  show "runtime exception" "failwith \"boom\";;";
  show "stdin is not ours to steal" "x * 2;;";
  (* completion over the live environment *)
  let start, words = UTop_complete.complete ~phrase_terminator:";;" ~input:"List.ma" in
  say (Printf.sprintf "COMPLETE start=%d n=%d : %s" start (List.length words)
         (String.concat " " (List.map fst words)))
