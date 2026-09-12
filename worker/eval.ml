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

(* The rewrite of [%break] calls a value, so the value has to exist before a
   phrase carrying a marker can be typed. It is declared by evaluating an
   ordinary phrase, which gives it a type without building a value
   description by hand, and the real closure is then put underneath it. A
   session can see the name; that is the price of not shipping an interface
   file beside the worker for it. *)
let install_break_hook () =
  let declare name ty value =
    let src = Printf.sprintf "let %s : %s = Obj.magic 0;;" name ty in
    (match Toplevel.parse src with
     | Ok phrases ->
       List.iter
         (fun p ->
            (* Never printed: the declaration is ours, not the caller's. *)
            try ignore (Toploop.execute_phrase false Format.err_formatter p)
            with _ -> ())
         phrases
     | Error _ -> ());
    Toploop.setvalue name value
  in
  declare Breakpoint.local_hook_name Breakpoint.local_hook_type
    (Obj.repr Breakpoint.local_hook);
  declare Breakpoint.hook_name Breakpoint.hook_type (Obj.repr Breakpoint.hook);
  (* Defined in the session so that abandoning a phrase renders as
     "Exception: Camlkit_abandoned." rather than as this worker's internal
     module path. *)
  let src =
    Printf.sprintf "exception %s;;\nlet %s = %s;;"
      Breakpoint.abandoned_name Breakpoint.abandoned_binding
      Breakpoint.abandoned_name
  in
  (match Toplevel.parse src with
   | Ok phrases ->
     List.iter
       (fun p ->
          try ignore (Toploop.execute_phrase false Format.err_formatter p)
          with _ -> ())
       phrases;
     (try
        Breakpoint.abandoned :=
          (Obj.magic (Toploop.getvalue Breakpoint.abandoned_binding) : exn)
      with _ -> ())
   | Error _ -> ())

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
  install_break_hook ();
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
let typecheck_all ~autorun phrases =
  let env0 = !Toploop.toplevel_env in
  let restore () = Toploop.toplevel_env := env0 in
  let rec go i acc = function
    | [] -> restore (); Ok (List.rev acc)
    | (Parsetree.Ptop_dir _ as d) :: rest -> go (i + 1) ((d, None) :: acc) rest
    | Parsetree.Ptop_def str0 :: rest ->
      (* A marker cannot be typed as it stands, so it becomes a call with no
         locals first. What is in scope at it is only knowable from the typed
         tree, which is why the locals arrive in a second rewrite. *)
      let breaking = Breakpoint.has_marker str0 in
      let str, marker_locs =
        if breaking then Breakpoint.rewrite_empty str0 else (str0, []) in
      (match Typemod.type_toplevel_phrase !Toploop.toplevel_env str with
       | (tstr, _, _, _, env) ->
         let env_before = !Toploop.toplevel_env in
         let str', fired = Autorun.rewrite ~enabled:autorun env_before str tstr in
         if breaking && fired <> None then begin
           restore ();
           (* Escaping a blocking run leaves the scheduler unable to start
              another, which would break every later promise phrase in the
              session. Refused before anything runs rather than left as a
              trap; see docs/wayfinder/tickets/035. *)
           Error Msg.{ phase = Typecheck; phrase_index = i;
                       message =
                         "A breakpoint cannot sit inside a phrase that \
                          autorun will run as a promise: stopping escapes the \
                          run, which leaves the scheduler unable to start \
                          another. Pass autorun: [] for this call, or run the \
                          promise yourself.";
                       spans = []; lines = []; done_ = [] }
         end else begin
           let str' =
             if not breaking then str'
             else
               let before = Breakpoint.value_identities env_before in
               let locals =
                 List.map
                   (function
                     | None -> []
                     | Some env -> Breakpoint.locals_at ~before env)
                   (Breakpoint.marker_envs tstr marker_locs)
               in
               (* The markers are gone from [str], which is the tree that was
                  typed; the second rewrite starts again from the caller's
                  own tree. *)
               Breakpoint.rewrite_with locals str0
           in
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
         end
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
(* The handler sits around each phrase rather than around the request, so the
   phrases that finished before a stop stay accounted for exactly as they are
   for an interrupt. Deep, so a resumed phrase that stops again is caught by
   the same handler and comes back to whoever resumed it. *)
let run_phrase ppf buf phrase =
  try
    Effect.Deep.match_with
      (fun () -> Breakpoint.Ran (with_heap_limit
                        (fun () -> Toploop.execute_phrase true ppf phrase)))
      ()
      { Effect.Deep.retc = (fun step -> step);
        exnc = (fun e -> raise e);
        effc = (fun (type c) (eff : c Effect.t) ->
            match eff with
            | Breakpoint.Stop locals ->
              Some (fun (k : (c, Breakpoint.step) Effect.Deep.continuation) ->
                  Breakpoint.Broke (locals, k))
            | _ -> None) }
  with exn -> Buffer.add_string buf (message_of_exn exn); Breakpoint.Ran false

(* Binding a local is declaring a name of the printed type and then putting
   the value underneath it, which is how a type that cannot be written outside
   the phrase is detected: the declaration simply fails to compile, and the
   compiler's own message becomes the reason it was skipped. A weak variable,
   a locally abstract type and an existential all land here. *)
let bind_locals (locals : Breakpoint.local list) =
  let bound = ref [] and skipped = ref [] in
  List.iter
    (fun (l : Breakpoint.local) ->
       let name = "bp_" ^ l.Breakpoint.name in
       let src = Printf.sprintf "let %s : %s = Obj.magic 0;;" name l.Breakpoint.ty in
       if Breakpoint.has_type_variable l.Breakpoint.ty then
         skipped :=
           (l.Breakpoint.name,
            Printf.sprintf
              "its type at the stop is %s, which still has a type variable in \
               it. Binding it would let a later phrase pick any type for a \
               value that has one, and the toplevel would then read it \
               wrongly." l.Breakpoint.ty)
           :: !skipped
       else
       match Toplevel.parse src with
       | Error (message, _, _) -> skipped := (l.Breakpoint.name, message) :: !skipped
       | Ok phrases ->
         (match
            List.iter
              (fun p ->
                 (* Never printed: the dummy is a placeholder and rendering it
                    would read a value of the wrong shape. *)
                 ignore (Toploop.execute_phrase false Format.err_formatter p))
              phrases
          with
          | () ->
            Toploop.setvalue name l.Breakpoint.value;
            bound := Msg.{ bound = name; bound_type = l.Breakpoint.ty } :: !bound
          | exception exn ->
            skipped := (l.Breakpoint.name, message_of_exn exn) :: !skipped))
    locals;
  (List.rev !bound, List.rev !skipped)

(* Runs phrases from a given point, so a call that stopped can be finished
   later from where it left off. execute_all is this from the beginning. *)
let rec execute_from cap ~acc ~pos start phrases =
  let go = execute_from cap ~acc ~pos in
  match phrases with
  | [] -> Msg.Completed { phrases = List.rev !acc; autorun = None }
  | (phrase, ran) :: rest ->
    let i = start in
      let buf = Buffer.create 256 and wbuf = Buffer.create 64 in
      let ppf = Format.formatter_of_buffer buf in
      let wppf = Format.formatter_of_buffer wbuf in
      Location.formatter_for_warnings := wppf;
      interrupted := false;
      over_limit := false;
      (* Scan before and after, as utop does: a phrase may itself load the
         cmis carrying the printers it then wants to use. *)
      Printers.scan ppf;
      let step = run_phrase ppf buf phrase in
      let ok =
        match step with Breakpoint.Ran ok -> ok | Breakpoint.Broke _ -> true in
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
                         dropped = 0; bindings = Outcome.take ();
                         ran } in
      pos := stop;
      acc := record :: !acc;
      match step with
      | Breakpoint.Broke (locals, k) ->
        let bound, skipped = bind_locals locals in
        let id = Breakpoint.fresh_id () in
        Breakpoint.park { Breakpoint.id; k; locals; buf; wbuf;
                          seen = Buffer.length buf; rest; index = i };
        Msg.Stopped { id; phrase_index = i; bound; skipped;
                      done_ = List.rev !acc }
      | Breakpoint.Ran _ ->
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

let execute_all cap phrases =
  execute_from cap ~acc:(ref []) ~pos:(ref 0) 0 phrases

(* Echo the session's rule list on the way out. A caller that just changed it,
   or that wants to know whether the change stuck, should not have to evaluate
   a probe expression to find out. *)
(* The rules the call ran under, echoed on the way out: a rewrite is otherwise
   invisible, and a caller should not have to probe to learn what was in
   force. *)
let with_autorun rules = function
  | Msg.Completed { phrases; _ } ->
    Msg.Completed { phrases; autorun = Some rules }
  | other -> other

let eval cap ?autorun src =
  Capture.reset cap;
  let rules = Option.value autorun ~default:Autorun.default in
  match Autorun.check rules with
  (* A bad rule name is a rejected argument, not a failed phrase: nothing
     parsed, nothing ran, and Failed would name a phrase that is not at
     fault. *)
  | Error message -> Msg.Rejected message
  | Ok () ->
  match parse src with
  | Error f -> Msg.Failed f
  | Ok phrases ->
    match
      List.filter_map
        (function
          | Parsetree.Ptop_def str -> Breakpoint.malformed_marker str
          | Parsetree.Ptop_dir _ -> None)
        phrases
    with
    | _ :: _ ->
      Msg.Rejected
        "A breakpoint is written [%break], with no payload, where an \
         expression belongs. As a structure item ([%%break]) or with a \
         payload it is not a breakpoint, and the compiler reports it as an \
         uninterpreted extension."
    | [] ->
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
      match typecheck_all ~autorun:rules phrases with
      | Error f -> Msg.Failed f
      | Ok typed ->
        (* Which rule fired is known only from this first pass: by the second
           a bare expression has become a let, so nothing there matches. *)
        let fired = List.map snd typed in
        let phrases, next =
          bind_expressions !implicit_counter (List.map fst typed) in
        (match typecheck_all ~autorun:rules phrases with
         | Error f -> Msg.Failed f
         | Ok typed ->
           implicit_counter := next;
           let phrases = List.combine (List.map fst typed) fired in
           with_autorun rules (execute_all cap phrases))

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
                                out_len = Capture.mark cap; dropped = 0;
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

(* --- parked phrases ----------------------------------------------------- *)

let resolve id =
  let listing () =
    match Breakpoint.ids () with
    | [] -> "no phrase is parked in this session"
    | ids ->
      Printf.sprintf "parked: %s"
        (String.concat ", " (List.map string_of_int ids))
  in
  match Breakpoint.ids (), id with
  | [], _ -> Error "no phrase is parked in this session"
  | _, Some id ->
    (match Breakpoint.find id with
     | Some p -> Ok p
     | None ->
       Error (Printf.sprintf "no phrase is parked with id %d. %s" id (listing ())))
  | _, None ->
    match Breakpoint.the_only_one () with
    | Some id -> Ok (Option.get (Breakpoint.find id))
    | None ->
      Error (Printf.sprintf "which parked phrase? Give an id. %s" (listing ()))

(* The rest of a resumed phrase prints into the buffers the original call
   handed execute_phrase, which are inside the continuation and cannot be
   swapped. They were kept with the continuation, so what the rest of the
   phrase adds is read from them here. *)
let record_of_parked cap (p : Breakpoint.parked) =
  let rendering =
    let all = Buffer.contents p.Breakpoint.buf in
    if String.length all <= p.Breakpoint.seen then ""
    else String.sub all p.Breakpoint.seen
           (String.length all - p.Breakpoint.seen)
  in
  Msg.{ rendering; warnings = Buffer.contents p.Breakpoint.wbuf;
        out_start = 0; out_len = Capture.mark cap;
        dropped = 0; bindings = Outcome.take (); ran = None }

let continue_ cap ~id ~abandon =
  Capture.reset cap;
  match resolve id with
  | Error why -> Msg.Rejected why
  | Ok p ->
    Breakpoint.forget p.Breakpoint.id;
    interrupted := false;
    over_limit := false;
    let step =
      try
        if abandon then
          Effect.Deep.discontinue p.Breakpoint.k !Breakpoint.abandoned
        else Effect.Deep.continue p.Breakpoint.k ()
      with
      | exn when exn == !Breakpoint.abandoned ->
        Buffer.add_string p.Breakpoint.buf
          "The phrase was abandoned at its breakpoint. Anything it had set up \
           to release on the way out has been released.\n";
        Breakpoint.Ran false
      | exn ->
        Buffer.add_string p.Breakpoint.buf (message_of_exn exn);
        Breakpoint.Ran false
    in
    (match step with
     | Breakpoint.Ran _ ->
       (* The phrase is done, and so is the part of the call that was waiting
          behind it: a stop suspends the call, not only the phrase. *)
       let record = record_of_parked cap p in
       execute_from cap ~acc:(ref [ record ]) ~pos:(ref (Capture.mark cap))
         (p.Breakpoint.index + 1) p.Breakpoint.rest
     | Breakpoint.Broke (locals, k) ->
       (* Stopped again: the same phrase, a later marker, a new id. *)
       let record = record_of_parked cap p in
       let bound, skipped = bind_locals locals in
       let id = Breakpoint.fresh_id () in
       Breakpoint.park { p with Breakpoint.id; k; locals;
                                seen = Buffer.length p.Breakpoint.buf };
       Msg.Stopped { id; phrase_index = p.Breakpoint.index; bound; skipped;
                     done_ = [ record ] })

(* Looking is not resuming. Binding again is what makes an older stop
   reachable after a later one overwrote the names, and rendering is done by
   rebinding each name to itself, so the value is printed by the session's own
   printers rather than by a second rendering path here. *)
let inspect cap ~id =
  Capture.reset cap;
  match resolve id with
  | Error why -> Msg.Rejected why
  | Ok p ->
    let bound, skipped = bind_locals p.Breakpoint.locals in
    let buf = Buffer.create 256 in
    let ppf = Format.formatter_of_buffer buf in
    List.iter
      (fun (b : Msg.binding) ->
         let src = Printf.sprintf "let %s = %s;;" b.Msg.bound b.Msg.bound in
         match Toplevel.parse src with
         | Error _ -> ()
         | Ok phrases ->
           List.iter
             (fun phrase ->
                try ignore (Toploop.execute_phrase true ppf phrase) with _ -> ())
             phrases)
      bound;
    Format.pp_print_flush ppf ();
    ignore (Outcome.take ());
    let record =
      Msg.{ rendering = Buffer.contents buf; warnings = "";
            out_start = 0; out_len = Capture.mark cap;
            dropped = 0; bindings = bound; ran = None }
    in
    Msg.Stopped { id = p.Breakpoint.id; phrase_index = -1; bound; skipped;
                  done_ = [ record ] }

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
