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

(* The ceiling on a phrase's heap, in MiB; see with_heap_limit below. *)
let heap_limit_mib = ref 2048
let heap_limit_words () = !heap_limit_mib * 1024 * 1024 / (Sys.word_size / 8)

let install_handler () =
  ignore (Sys.signal Sys.sigint
            (Sys.Signal_handle (fun _ -> interrupted := true; raise Sys.Break)))

let init () =
  Sys.interactive := false;
  Clflags.real_paths := false;          (* -short-paths *)
  Clflags.debug := true;                (* -g: see ticket 034 *)
  Toploop.initialize_toplevel_env ();
  (* utop used to do this for us. Without it Topfind has no configuration and
     every require fails; the byte predicate matters because this worker is
     bytecode and would otherwise be offered native archives. *)
  (* The ceiling is fixed, but a small machine may want it lower and a test
     needs it low enough to trip cheaply. *)
  (match Option.bind (Sys.getenv_opt "CAMLKIT_HEAP_LIMIT_MIB") int_of_string_opt with
   | Some n when n > 0 -> heap_limit_mib := n
   | _ -> ());
  Findlib.init ();
  (* ld.conf names <switch>/lib/ocaml/stublibs, but opam installs package
     stubs one level up in <switch>/lib/stublibs, and only opam env's
     CAML_LD_LIBRARY_PATH bridges the two. A client does not start us from
     that environment, so any package with C stubs would fail to load; see
     docs/wayfinder/tickets/028. Added to the search path rather than by
     setting the variable, which the user may have set deliberately. *)
  (let stubs = Filename.concat (Findlib.default_location ()) "stublibs" in
   if Sys.file_exists stubs then Dll.add_path [ stubs ]);
  Topfind.add_predicates [ "byte" ];
  Topfind.don't_load_deeply [ "compiler-libs.toplevel" ];
  (* utop sets this in common_init; it names the buffer in compiler messages. *)
  Location.input_name := Toplevel.input_name;
  Outcome.install ();
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

let message_of_exn = Toplevel.message_of_exn

let parse src =
  match Toplevel.parse src with
  | Ok phrases -> Ok phrases
  | Error (message, spans, lines) ->
    Error Msg.{ phase = Parse; phrase_index = -1; message; spans; lines;
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

(* Types every phrase against an advancing environment, and returns the
   phrases that will actually run: an Lwt or Async expression is rewritten to
   run rather than to hand back a promise, which needs the typed tree and so
   happens here. See worker/autorun.ml. *)
let typecheck_all phrases =
  let env0 = !Toploop.toplevel_env in
  let restore () = Toploop.toplevel_env := env0 in
  let rec go i acc = function
    | [] -> restore (); Ok (List.rev acc)
    | (Parsetree.Ptop_dir _ as d) :: rest -> go (i + 1) ((d, None) :: acc) rest
    | Parsetree.Ptop_def str :: rest ->
      (match Typemod.type_toplevel_phrase !Toploop.toplevel_env str with
       | (tstr, _, _, _, env) ->
         let env_before = !Toploop.toplevel_env in
         let str', fired = Autorun.rewrite env_before str tstr in
         (* A rewritten phrase has a different type - unit rather than a
            promise - so it has to be typed again for the environment the next
            phrase sees to be right. *)
         let env =
           if str' == str then env
           else
             match Typemod.type_toplevel_phrase env_before str' with
             | (_, _, _, _, env) -> env
             | exception _ -> env
         in
         Toploop.toplevel_env := env;
         go (i + 1) ((Parsetree.Ptop_def str', fired) :: acc) rest
       | exception exn ->
         let message, spans, lines = Toplevel.describe_exn exn in
         restore ();
         Error Msg.{ phase = Typecheck; phrase_index = i; message; spans; lines;
                     done_ = [] })
  in
  go 0 [] phrases

(* Nothing bounded a phrase's allocation: a runaway one took the machine with
   it and the worker died by the kernel's hand rather than ours, losing the
   session. A Gc alarm runs at the end of every major cycle, so a ceiling
   checked there stops the phrase while the heap is still ours to unwind, the
   same way the deadline stops one that will not return.

   Armed only while a phrase runs, so nothing can trip while the response is
   being built. The reading is the heap's size rather than its live words:
   quick_stat does not walk the heap, and a heap that has grown this far is
   the thing being bounded. That is also why the catch compacts - without it
   the heap stays at the ceiling and the next phrase trips at once.

   ponytail: one fixed ceiling for every session, make it an argument if
   anyone needs a bigger one. *)
exception Over_heap_limit


(* Detected by a flag, not by catching the exception, for the same reason as
   the interrupt: execute_phrase catches what evaluated code raises and turns
   it into a printed rendering, so the exception never reaches us. *)
let over_limit = ref false

let with_heap_limit f =
  let alarm =
    Gc.create_alarm (fun () ->
        if (Gc.quick_stat ()).Gc.heap_words > heap_limit_words () then begin
          over_limit := true; raise Over_heap_limit
        end)
  in
  Fun.protect ~finally:(fun () -> Gc.delete_alarm alarm) f

(* execute_phrase swallows Sys.Break itself, printing "Interrupted." and
   returning false, so an interrupt is detected by the handler's flag rather
   than by catching an exception. It does raise on compile errors, which the
   typing pass should have caught already; the guard stays because an
   unreachable path that kills the worker is not worth the saving. *)
let execute_all cap phrases =
  let acc = ref [] and pos = ref 0 in
  let rec go i = function
    | [] -> Msg.Completed { phrases = List.rev !acc; autorun = None }
    | (phrase, ran) :: rest ->
      let buf = Buffer.create 256 and wbuf = Buffer.create 64 in
      let ppf = Format.formatter_of_buffer buf in
      let wppf = Format.formatter_of_buffer wbuf in
      Location.formatter_for_warnings := wppf;
      interrupted := false;
      over_limit := false;
      (* Scan before and after, as utop does: a phrase may itself load the
         cmis carrying the printers it then wants to use. *)
      Printers.scan ppf;
      let ok =
        try with_heap_limit (fun () -> Toploop.execute_phrase true ppf phrase)
        with exn -> Buffer.add_string buf (message_of_exn exn); false
      in
      let ok =
        if not !over_limit then ok
        else begin
          (* Give the heap back: the ceiling reads its size, so without this
             the next phrase trips on the runaway one's garbage. *)
          Gc.compact ();
          Buffer.clear buf;
          Buffer.add_string buf
            (Printf.sprintf
               "Exception: the phrase was stopped after the heap passed %d \
                MiB, which is this worker's ceiling. The session is still \
                usable and its earlier bindings are intact.\n"
               !heap_limit_mib);
          false
        end
      in
      Printers.scan ppf;
      Format.pp_print_flush ppf (); Format.pp_print_flush wppf ();
      let stop = Capture.mark cap in
      let record = Msg.{ rendering = Buffer.contents buf;
                         warnings = Buffer.contents wbuf;
                         out_start = !pos; out_len = stop - !pos;
                         truncated = false; bindings = Outcome.take ();
                         ran } in
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

(* Echo the session's rule list on the way out. A caller that just changed it,
   or that wants to know whether the change stuck, should not have to evaluate
   a probe expression to find out. *)
let with_autorun = function
  | Msg.Completed { phrases; _ } ->
    Msg.Completed { phrases; autorun = Some (Autorun.current ()) }
  | other -> other

let eval cap ?autorun src =
  Capture.reset cap;
  match
    match autorun with
    | None -> Ok ()
    | Some names -> Autorun.set names
  with
  (* A bad rule name is a rejected argument, not a failed phrase: nothing
     parsed, nothing ran, and Failed would name a phrase that is not at
     fault. The message carries the rules still in force, since set is all or
     nothing and a refusal leaves the session as it was. *)
  | Error message ->
    Msg.Rejected
      (Printf.sprintf "%s. The session is still set to: %s" message
         (match Autorun.current () with
          | [] -> "no rules" | rs -> String.concat ", " rs))
  | Ok () ->
  match parse src with
  | Error f -> Msg.Failed f
  | Ok phrases ->
    match reject_directives phrases with
    | Some d ->
      (* Not "use the tool for it": most directives have no tool and are not
         going to get one; see tickets/029. Naming the two that do is the
         useful half of the message. *)
      Msg.Rejected
        (Printf.sprintf
           "eval does not accept directives, and #%s is one. Loading a \
            library is the require and load tools, and showing a signature \
            is describe; the rest of the directives are not part of the \
            tool surface." d)
    | None ->
      (* Rewrite before typing, so the pre-check sees exactly what will run.
         The counter only advances once the whole request typechecks, so a
         rejected request leaves no gap in the numbering. *)
      (* Auto-run first, then implicit names: after a bare expression becomes
         "let _N = ...", it is no longer an expression to rewrite. *)
      match typecheck_all phrases with
      | Error f -> Msg.Failed f
      | Ok typed ->
        (* Which rule fired is known only from this first pass: by the second
           a bare expression has become a let, so nothing there matches. *)
        let fired = List.map snd typed in
        let phrases, next =
          bind_expressions !implicit_counter (List.map fst typed) in
        (match typecheck_all phrases with
         | Error f -> Msg.Failed f
         | Ok typed ->
           implicit_counter := next;
           let phrases = List.combine (List.map fst typed) fired in
           with_autorun (execute_all cap phrases))

(* Not the #require directive, and not UTop.require: both swallow findlib
   errors into printed text, so a missing package reported as success. Worse,
   UTop.require reports through Lwt_main.run, which would start an Lwt loop
   inside a worker that deliberately has none. *)
let require_packages cap packages =
  match
  try
    Topfind.load (Findlib.package_deep_ancestors !Topfind.predicates packages);
    Ok ()
  with
  | Fl_package_base.No_such_package (pkg, reason) ->
    Error (Printf.sprintf "no such package: %s%s" pkg
             (if reason = "" then "" else " - " ^ reason))
  | Fl_package_base.Package_loop pkg -> Error ("package requires itself: " ^ pkg)
  | Failure m -> Error m
  (* Anything else is still a package that did not load, which require
     already has a field for. In particular a missing C stub raises
     Compenv.Exit_with_status, which used to escape and end the worker,
     losing the session over one bad package; see tickets/028. The toplevel
     printed the detail to stderr, which is captured and returned. *)
  | Compenv.Exit_with_status _ ->
    Error "the toplevel aborted the load, commonly a shared library it could \
           not open"
  | e -> Error (Printexc.to_string e)
  with
  | Ok () -> Ok ()
  (* The detail is on stderr, which is captured, and neither a failed library
     nor a failed load carries the captured output back on its own. *)
  | Error message ->
    (match String.trim (fst (Capture.contents cap)) with
     | "" -> Error message
     | detail -> Error (message ^ "\n" ^ detail))

let ok_result cap rendering =
  Msg.Completed { phrases = [ { rendering; warnings = ""; out_start = 0;
                                out_len = Capture.mark cap; truncated = false;
                                bindings = []; ran = None } ];
                  autorun = None }

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
     | ps -> require_packages cap ps)
  with
  | Error e -> fail_result ("could not load required packages: " ^ e)
  | Ok () ->
  match Loader.load ~libraries path with
  | Error e -> fail_result e
  | Ok (loaded, failed) -> Msg.Loaded { loaded; failed }

(* Directive-backed operations. These bypass the typing pass by design:
   directives are not typeable, which is why they are not allowed in eval. *)
let directive cap src =
  Capture.reset cap;
  match parse src with
  | Error f -> Msg.Failed f
  | Ok phrases -> execute_all cap (List.map (fun p -> (p, None)) phrases)

(* Directives print to stdout, not to the formatter passed to execute_phrase,
   so the answer arrives in the captured output with an empty rendering. *)
let describe cap path = directive cap (Printf.sprintf "#show %s;;" path)

(* Reports which packages are now loaded rather than an empty phrase result:
   a caller should not have to infer success from the absence of an error. *)
let require cap packages =
  Capture.reset cap;
  match require_packages cap packages with
  | Ok () -> Msg.Loaded { loaded = packages; failed = [] }
  | Error message ->
    Msg.Loaded { loaded = [];
                 failed = List.map (fun p -> (p, message)) packages }
