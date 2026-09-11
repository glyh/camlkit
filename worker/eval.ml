(* This module is imperative shell by necessity: Toploop and Typemod work
   through global compiler state, so there is no pure core to extract from
   evaluation itself. The parts that are pure - directive rejection, response
   construction - are kept separable regardless.

   Two-pass evaluation: type every phrase against an advancing environment
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
  (* utop sets this in common_init; it names the buffer in compiler messages. *)
  Location.input_name := UTop.input_name;
  (* UTop_main installs print_out_signature and print_out_phrase hooks from a
     module initializer, and -linkall means they now run. They hide
     identifiers beginning with an underscore, which is exactly what our
     implicit bindings are called, so a bare expression rendered as nothing at
     all. This is what -show-reserved does in the utop binary. *)
  UTop.set_hide_reserved false;
  Printers.prime ();
  install_handler ()

(* Give every bare expression a name, so <expr>;; becomes let _N = <expr>;;
   and an agent can refer back to an earlier result.

   UTop.set_create_implicits only sets a flag that UTop_main.bind_expressions
   reads, and that function is not exported, so setting it here did nothing at
   all. The rewrite is small enough to own. *)
let implicit_counter = ref 0

let bind_expressions start phrases =
  let n = ref start in
  let rewrite_item item =
    let open Parsetree in
    match item with
    | { pstr_desc = Pstr_eval (expr, attrs); pstr_loc = loc } ->
      let name = Printf.sprintf "_%d" !n in
      incr n;
      Ast_helper.Str.value ~loc Nonrecursive
        [ Ast_helper.Vb.mk ~loc ~attrs
            (Ast_helper.Pat.var ~loc { Asttypes.txt = name; loc }) expr ]
    | other -> other
  in
  let rewrite = function
    | Parsetree.Ptop_def items -> Parsetree.Ptop_def (List.map rewrite_item items)
    | Parsetree.Ptop_dir _ as d -> d
  in
  (* Bound, not inlined into the tuple: OCaml evaluates tuple components
     right to left, so [!n] would be read before the map ran. *)
  let rewritten = List.map rewrite phrases in
  (rewritten, !n)

let message_of_exn exn = Location.reset (); UTop.get_message Errors.report_error exn

(* One call, not two. get_ocaml_error_message recovers the location by
   Scanf-ing its own rendering of the error, and OCaml's reporter inserts a
   separating newline before every report after the first. So rendering the
   message beforehand shifts the text and the scan silently falls back to
   (0, 0). Taking the message from here as well avoids that, and it arrives
   with the location prefix already stripped.

   Both location forms are reported: byte offsets into the submitted source
   for exact slicing, line ranges for anything that reads like a compiler
   message. *)
let describe_exn exn =
  (* Location keeps a counter of lines already reported and emits a separator
     before every later report, which shifts the text the scan depends on.
     That state outlives a request, so reset it per error, not per session. *)
  Location.reset ();
  match UTop.get_ocaml_error_message exn with
  | (start, stop), message, lines ->
    (message, [ (start, stop) ],
     match lines with
     | Some { UTop.start; stop } -> [ (start, stop) ]
     | None -> [])
  | exception _ -> (Printexc.to_string exn, [], [])

let parse src =
  match !UTop.parse_use_file src false with
  | UTop.Value phrases -> Ok phrases
  | UTop.Error (spans, message) ->
    Error Msg.{ phase = Parse; phrase_index = -1; message; spans; lines = [];
                done_ = [] }

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
         let message, spans, lines = describe_exn exn in
         restore ();
         Error Msg.{ phase = Typecheck; phrase_index = i; message; spans; lines;
                     done_ = [] })
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
      (* Scan before and after, as utop does: a phrase may itself load the
         cmis carrying the printers it then wants to use. *)
      Printers.scan ppf;
      let ok =
        try Toploop.execute_phrase true ppf phrase
        with exn -> Buffer.add_string buf (message_of_exn exn); false
      in
      Printers.scan ppf;
      Format.pp_print_flush ppf (); Format.pp_print_flush wppf ();
      let stop = Capture.mark cap in
      let record = Msg.{ rendering = Buffer.contents buf;
                         warnings = Buffer.contents wbuf;
                         out_start = !pos; out_len = stop - !pos;
                         truncated = false } in
      pos := stop;
      acc := record :: !acc;
      if !interrupted then
        Msg.Interrupted { phrase_index = i; done_ = List.rev !acc }
      else if ok then go (i + 1) rest
      else
        (* The phrases before this one really ran. Keep their records, and
           this one's, so their output is not thrown away with the error. *)
        Msg.Failed { phase = Execute; phrase_index = i;
                     message = record.Msg.rendering; spans = []; lines = [];
                     (* everything except the failing phrase, whose rendering
                        is already the message *)
                     done_ = List.rev (List.tl !acc) }
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
      (* Rewrite before typing, so the pre-check sees exactly what will run.
         The counter only advances once the whole request typechecks, so a
         rejected request leaves no gap in the numbering. *)
      let phrases, next = bind_expressions !implicit_counter phrases in
      match typecheck_all phrases with
      | Error f -> Msg.Failed f
      | Ok () -> implicit_counter := next; execute_all cap phrases

(* Not the #require directive, and not UTop.require: both swallow findlib
   errors into printed text, so a missing package reported as success. Worse,
   UTop.require reports through Lwt_main.run, which would start an Lwt loop
   inside a worker that deliberately has none. *)
let require_packages packages =
  try
    Topfind.load (Findlib.package_deep_ancestors !Topfind.predicates packages);
    Ok ()
  with
  | Fl_package_base.No_such_package (pkg, reason) ->
    Error (Printf.sprintf "no such package: %s%s" pkg
             (if reason = "" then "" else " - " ^ reason))
  | Fl_package_base.Package_loop pkg -> Error ("package requires itself: " ^ pkg)
  | Failure m -> Error m

let ok_result cap rendering =
  Msg.Completed [ { rendering; warnings = ""; out_start = 0;
                    out_len = Capture.mark cap; truncated = false } ]

let fail_result message =
  Msg.Failed { phase = Msg.Execute; phrase_index = 0; message;
               spans = []; lines = []; done_ = [] }

(* Load a dune project's private libraries. Not an eval: it changes the search
   path and loads archives, neither of which can share a call with code that
   uses them, since nothing runs until every phrase typechecks. *)
let load cap ~libraries ~packages path =
  Capture.reset cap;
  match
    (match packages with
     | [] -> Ok ()
     | ps -> require_packages ps)
  with
  | Error e -> fail_result ("could not load required packages: " ^ e)
  | Ok () ->
  match Loader.load ~libraries path with
  | Error e -> fail_result e
  | Ok (loaded, failed) ->
    let name a = Filename.remove_extension (Filename.basename a) in
    let summary =
      Printf.sprintf "loaded %d librar%s: %s" (List.length loaded)
        (if List.length loaded = 1 then "y" else "ies")
        (String.concat ", " (List.map name loaded))
    in
    if failed = [] then ok_result cap summary
    else
      let detail =
        String.concat "\n"
          (List.map (fun (a, e) -> Printf.sprintf "%s: %s" (name a) e) failed)
      in
      if loaded = [] then fail_result detail
      else ok_result cap (summary ^ "\n\nnot loaded:\n" ^ detail)

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
  Capture.reset cap;
  match require_packages packages with
  | Ok () ->
    Msg.Completed [ { rendering = ""; warnings = "";
                      out_start = 0; out_len = Capture.mark cap;
                      truncated = false } ]
  | Error message ->
    Msg.Failed { phase = Msg.Execute; phrase_index = 0; message;
                 spans = []; lines = []; done_ = [] }
