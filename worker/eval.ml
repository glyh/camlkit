(* Two-pass evaluation: type every phrase against an advancing environment
   without running anything, then execute only if all of them typed. So
   neither a syntax error nor a type error leaves partial state behind.
   Note this cannot reuse UTop.check_phrase, which wraps items in a dummy
   function and restores the environment, so its checks do not compose
   across phrases. *)

open Wire

let interrupted = ref false

let install_handler () =
  ignore (Sys.signal Sys.sigint
            (Sys.Signal_handle (fun _ -> interrupted := true; raise Sys.Break)))

let init () =
  Sys.interactive := false;
  Clflags.real_paths := false;          (* -short-paths *)
  Toploop.initialize_toplevel_env ();
  UTop.set_create_implicits true;       (* <expr>;; binds _0, _1, ... *)
  install_handler ()

let message_of_exn exn = UTop.get_message Errors.report_error exn

let spans_of_exn exn =
  match UTop.get_ocaml_error_message exn with
  | loc, _, _ -> [ loc ]
  | exception _ -> []

let parse src =
  match !UTop.parse_use_file src false with
  | UTop.Value phrases -> Ok phrases
  | UTop.Error (spans, message) ->
    Error Msg.{ phase = Parse; phrase_index = -1; message; spans }

(* Directives are not typeable, so skipping them in the typing pass falsely
   rejects valid code: "#require \"yojson\";; Yojson.Safe.from_string ..."
   fails with Unbound module Yojson. Rather than special-case them, eval
   refuses them and they get their own tools. *)
let directive_name = function
  | Parsetree.Ptop_dir { pdir_name = { txt; _ }; _ } -> Some txt
  | Parsetree.Ptop_def _ -> None

let reject_directives phrases =
  let rec go = function
    | [] -> None
    | p :: rest ->
      (match directive_name p with
       | Some d -> Some d
       | None -> go rest)
  in
  go phrases

let typecheck_all phrases =
  let env0 = !Toploop.toplevel_env in
  let restore () = Toploop.toplevel_env := env0 in
  let rec go i = function
    | [] -> restore (); Ok ()
    | Parsetree.Ptop_dir _ :: rest -> go (i + 1) rest   (* unreachable: rejected above *)
    | Parsetree.Ptop_def str :: rest ->
      (match Typemod.type_toplevel_phrase !Toploop.toplevel_env str with
       | (_, _, _, _, env) -> Toploop.toplevel_env := env; go (i + 1) rest
       | exception exn ->
         let message = message_of_exn exn and spans = spans_of_exn exn in
         restore ();
         Error Msg.{ phase = Typecheck; phrase_index = i; message; spans })
  in
  go 0 phrases

(* execute_phrase swallows Sys.Break itself, printing "Interrupted." and
   returning false, so an interrupt is detected by the handler's flag rather
   than by catching an exception. It does raise on compile errors, which the
   typing pass should have caught already; the guard stays because an
   unreachable path that kills the worker is not worth the saving. *)
let execute_all cap phrases =
  let acc = ref [] and pos = ref 0 in
  let rec go i = function
    | [] -> Msg.Completed (List.rev !acc)
    | phrase :: rest ->
      let buf = Buffer.create 256 and wbuf = Buffer.create 64 in
      let ppf = Format.formatter_of_buffer buf in
      let wppf = Format.formatter_of_buffer wbuf in
      Location.formatter_for_warnings := wppf;
      interrupted := false;
      let ok =
        try Toploop.execute_phrase true ppf phrase
        with exn -> Buffer.add_string buf (message_of_exn exn); false
      in
      Format.pp_print_flush ppf (); Format.pp_print_flush wppf ();
      let stop = Capture.mark cap in
      let record = Msg.{ rendering = Buffer.contents buf;
                         warnings = Buffer.contents wbuf;
                         out_start = !pos; out_len = stop - !pos } in
      pos := stop;
      acc := record :: !acc;
      if !interrupted then
        Msg.Interrupted { phrase_index = i; done_ = List.rev !acc }
      else if ok then go (i + 1) rest
      else
        Msg.Failed { phase = Execute; phrase_index = i;
                     message = record.Msg.rendering; spans = [] }
  in
  go 0 phrases

let eval cap src =
  Capture.reset cap;
  match parse src with
  | Error f -> Msg.Failed f
  | Ok phrases ->
    match reject_directives phrases with
    | Some d ->
      Msg.Rejected
        (Printf.sprintf
           "eval does not accept directives; #%s belongs to a dedicated tool" d)
    | None ->
      match typecheck_all phrases with
      | Error f -> Msg.Failed f
      | Ok () -> execute_all cap phrases

(* Directive-backed operations. These bypass the typing pass by design:
   directives are not typeable, which is why they are not allowed in eval. *)
let directive cap src =
  Capture.reset cap;
  match parse src with
  | Error f -> Msg.Failed f
  | Ok phrases -> execute_all cap phrases

(* Directives print to stdout, not to the formatter passed to execute_phrase,
   so the answer arrives in the captured output with an empty rendering. *)
let describe cap path = directive cap (Printf.sprintf "#show %s;;" path)

let require cap packages =
  directive cap
    (String.concat "" (List.map (Printf.sprintf "#require %S;;") packages))
