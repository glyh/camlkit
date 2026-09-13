(* MCP tool declarations. Each carries an outputSchema so results arrive as
   structuredContent rather than as prose the agent must re-parse: the worker
   already separates the toplevel's rendering from program output, warnings
   and error spans, and flattening that would throw the structure away. *)

let session_arg =
  ("session", `Assoc [ "type", `String "string";
                       "description", `String "Session name, defaulting to \
                         \"main\". Sessions are independent toplevels and \
                         state persists between calls, so name one only to \
                         keep work apart from what is already in main." ])

let obj ?(required = []) props =
  `Assoc [ "type", `String "object";
           "properties", `Assoc props;
           "required", `List (List.map (fun r -> `String r) required) ]

(* Every field here is absent when it has nothing to say: no bindings, no
   rendering, no warnings, no output. A result is read by a model, so an empty
   string costs tokens for no information. *)
let phrase_schema =
  `Assoc [ "type", `String "object";
           "properties", `Assoc [
             "rendering", `Assoc [ "type", `String "string";
               "description", `String "What the toplevel printed about the \
                 phrase, verbatim: each name it bound with its type and its \
                 value, as a utop transcript. This is where a phrase's \
                 bindings are read." ];
             "warnings", `Assoc [ "type", `String "string" ];
             "output", `Assoc [ "type", `String "string";
               "description", `String "What the phrase printed. If it printed \
                 more than the limit, this ends with [output truncated, N \
                 more characters]." ];
             "ran", `Assoc [ "type", `String "string";
               "description", `String "The autorun rule that rewrote this \
                 phrase, if one did: the expression was a promise and was run \
                 rather than returned. Absent when nothing was rewritten." ];
             "watched", `Assoc [ "type", `String "array";
               "description", `String "What the watches reached while this \
                 phrase ran: each site's name, the values it recorded during \
                 this phrase, and hits, which is its lifetime count rather \
                 than this phrase's. Consecutive equal values are counted and \
                 stored once, so a loop that changes nothing shows one value \
                 and many hits. Absent for a phrase that reached none." ];
             "cost", `Assoc [ "type", `String "object";
               "description", `String "wall_ms and allocated_bytes for this \
                 phrase, present only when the call asked for them. Both \
                 cover compiling, running and printing the phrase, not \
                 running it alone: a phrase that does little is mostly this \
                 floor, around 70 kB and a fraction of a millisecond, and one \
                 that prints a large value is mostly the printing. Compare \
                 two of these only when the work dwarfs that, which in \
                 practice means a loop inside the phrase. wall_ms is a single \
                 un-repeated run of bytecode and is not what a release build \
                 would cost." ] ] ]

let eval_tool =
  `Assoc [
    "name", `String "eval";
    "description", `String
      "Evaluate OCaml phrases in a session. Accepts several phrases in one \
       call, and nothing runs unless every one of them parses and typechecks, \
       so a failure leaves no partial state behind. That also means a phrase \
       cannot use something an earlier phrase in the same call put on the \
       search path; put such a change in its own call. Directives such as \
       #require are not accepted: loading a library is the require and load \
       tools, and showing a signature is describe. Write [%break \"name\"] in a \
       phrase to stop there and inspect it, then continue, or \
       [%watch \"name\" expr] to record every value that flows through an \
       expression without stopping at all. Both keep firing whenever the code \
       holding them runs; the markers tool lists them and turns them off. Pass \
       check to typecheck without running.";
    "inputSchema", obj ~required:[ "code" ]
      [ session_arg;
        ("code", `Assoc [ "type", `String "string";
                          "description", `String "OCaml source. Phrases are \
                            terminated with ;; as usual." ]);
        ("autorun", `Assoc
           [ "type", `String "array";
             "items", `Assoc [ "type", `String "string" ];
             "description", `String
               "For this call only. A bare expression whose type is a promise \
                is run rather than returned, which is what the default \
                [\"lwt\", \"async\"] does and what a session without those \
                libraries is unaffected by. Pass [] to get the promise \
                itself instead." ]);
        ("check", `Assoc
           [ "type", `String "boolean";
             "description", `String
               "Typecheck against this session and stop there: report each \
                phrase's type and nothing runs, so the session is unchanged \
                and no implicit name is used up. Use it for a candidate \
                rather than a step, or to ask what an expression's type would \
                be here. A rendering then says val f : int -> int with no \
                value, because there is no value without running it." ]);
        ("cost", `Assoc
           [ "type", `String "boolean";
             "description", `String
               "Report what each phrase cost: wall clock, and bytes allocated \
                from the runtime's own counters. Ask for it when you are \
                comparing two implementations, not by habit. The reading \
                covers compiling, running and printing the phrase, so there is \
                a floor of roughly 70 kB and a fraction of a millisecond that \
                is the toplevel's own work, and printing a large value costs \
                far more than that. Put the work in a loop inside the phrase \
                and the floor stops mattering: a phrase allocating 100000 \
                refs measures 1.61 MB against 1.6 MB expected. The allocation \
                is the sound half, being a count rather than a timing; the \
                wall clock is one un-repeated run of code the toplevel \
                compiled, which pays for any lazy initialisation it triggers \
                and is not what a release build would cost." ]) ];
    "outputSchema", obj [ ("phrases", `Assoc [ "type", `String "array";
                                               "items", phrase_schema ]);
                          ("autorun", `Assoc
                             [ "type", `String "array";
                               "items", `Assoc [ "type", `String "string" ];
                               "description", `String
                                 "The rules this call ran under, when they \
                                  were not the default. A rewritten phrase \
                                  credits its rule in the phrase's ran \
                                  field." ]);
                          ("checked", `Assoc
                             [ "type", `String "boolean";
                               "description", `String
                                 "Present when the call only typechecked. \
                                  Nothing ran and the session is \
                                  unchanged." ]) ] ]

let phrase_array =
  `Assoc [ "type", `String "array"; "items", phrase_schema ]

(* A marker is compiled into the code holding it, so it fires whenever that
   code runs and nothing can remove it short of redefining the function. This
   is what stops one: a flag the marker reads when it is reached. See
   docs/wayfinder/tickets/049. *)
let markers_tool =
  `Assoc [
    "name", `String "markers";
    "description", `String
      "The breakpoints and watches this session knows: each one's name, \
       whether it is armed, and how many times it has been reached in its \
       lifetime. Pass disarm to turn one off and arm to turn it back on. A \
       marker cannot be removed, because it is compiled into the code that \
       holds it, so a marker in a function you call often keeps firing until \
       you disarm it or redefine the function. Disarming a marker and then \
       re-evaluating its definition leaves it disarmed. A watch name can be \
       written in several places; each place is a site with its own id, shown \
       with the definition and line it is in, and can be armed on its own. A \
       breakpoint name written again is accepted with a warning, and a name \
       cannot be both a breakpoint and a watch.";
    "inputSchema", obj
      [ session_arg;
        ("disarm", `Assoc
           [ "type", `String "array";
             "items", `Assoc [ "type", `String "string" ];
             "description", `String
               "Names to turn off. A disarmed marker is still reached and \
                does nothing." ]);
        ("arm", `Assoc
           [ "type", `String "array";
             "items", `Assoc [ "type", `String "string" ];
             "description", `String "Names to turn back on." ]);
        ("disarm_sites", `Assoc
           [ "type", `String "array";
             "items", `Assoc [ "type", `String "integer" ];
             "description", `String
               "Site ids to turn off, for one place a watch name is written \
                rather than all of them." ]);
        ("arm_sites", `Assoc
           [ "type", `String "array";
             "items", `Assoc [ "type", `String "integer" ];
             "description", `String "Site ids to turn back on." ]) ];
    "outputSchema", obj
      [ ("markers", `Assoc
           [ "type", `String "array";
             "description", `String
               "Each with name, kind, armed and hits. hits is the site's \
                lifetime count, not this call's." ]);
        ("unknown", `Assoc
           [ "type", `String "array";
             "items", `Assoc [ "type", `String "string" ];
             "description", `String
               "Names passed to disarm or arm that this session has never \
                seen, so a typo is not silent. Absent when there are none." ]) ] ]

let describe_tool =
  `Assoc [
    "name", `String "describe";
    "description", `String
      "Show the signature of a module, value or type in a session, including \
       modules defined during the session. Prefer this over guessing at names.";
    "inputSchema", obj ~required:[ "path" ]
      [ session_arg;
        ("path", `Assoc [ "type", `String "string";
                          "description", `String "A module path such as \
                            List, or a value such as List.map." ]) ];
    "outputSchema", obj [ ("phrases", phrase_array) ] ]

let require_tool =
  `Assoc [
    "name", `String "require";
    "description", `String
      "Load findlib packages into a session, making their modules available \
       to later evaluations.";
    "inputSchema", obj ~required:[ "packages" ]
      [ session_arg;
        ("packages", `Assoc [ "type", `String "array";
                              "items", `Assoc [ "type", `String "string" ] ]) ];
    "outputSchema", obj
      [ ("status", `Assoc [ "type", `String "string" ]);
        ("loaded", `Assoc [ "type", `String "array";
                            "items", `Assoc [ "type", `String "string" ] ]);
        ("failed", `Assoc [ "type", `String "array";
                            "items", obj [ ("library", `Assoc [ "type", `String "string" ]);
                                           ("error", `Assoc [ "type", `String "string" ]) ] ]) ] ]

let load_tool =
  `Assoc [
    "name", `String "load";
    "description", `String
      "Load a dune project's own libraries into a session, so its modules \
       become available. Point it at the project root, the directory holding \
       dune-project. Build the project first; this loads what is already \
       compiled. External dependencies come with it, so there is no need to \
       require them separately. Pass reset after rebuilding: loading a changed \
       archive into a session that already has the old one fails on an \
       interface mismatch, so the session must start clean. The worker must \
       have been built with the same OCaml version as the project, because \
       bytecode is version-locked.";
    "inputSchema", obj
      [ session_arg;
        ("path", `Assoc [ "type", `String "string";
                          "description", `String "Project root, or a \
                            directory inside its _build tree. Defaults to the \
                            project the server was started in, which is the \
                            usual case." ]);
        ("libraries", `Assoc [ "type", `String "array";
                               "items", `Assoc [ "type", `String "string" ];
                               "description", `String "Library names to load. \
                                 Omit to load everything found." ]);
        ("reset", `Assoc [ "type", `String "boolean";
                           "description", `String "Empty the session first. \
                             Use after rebuilding the project." ]) ];
    "outputSchema", obj
      [ ("status", `Assoc [ "type", `String "string" ]);
        ("loaded", `Assoc [ "type", `String "array";
                            "items", `Assoc [ "type", `String "string" ];
                            "description", `String "Library names now loaded." ]);
        ("failed", `Assoc [ "type", `String "array";
                            "items", obj [ ("library", `Assoc [ "type", `String "string" ]);
                                           ("error", `Assoc [ "type", `String "string" ]) ] ]) ] ]

let reset_tool =
  `Assoc [
    "name", `String "reset";
    "description", `String
      "Discard a session and start it clean. Its bindings and loaded packages \
       are gone. Use this to get back to a known state rather than inventing \
       a new session name, which leaves the old toplevel running. Pass code \
       to evaluate it in the fresh toplevel in the same call, which is how a \
       preamble of helpers is put back; the result is then an eval's.";
    "inputSchema", obj ~required:[]
      [ session_arg;
        ("code", `Assoc [ "type", `String "string";
                          "description", `String "OCaml source to evaluate \
                            in the empty toplevel, in this call. \
                            Nothing is remembered: a session carries \
                            no preamble, so the next reset empties \
                            this too unless it carries the code \
                            again." ]) ];
    "outputSchema", obj [ ("status", `Assoc [ "type", `String "string" ]);
                          ("phrases", `Assoc [ "type", `String "array";
                                               "items", phrase_schema;
                                               "description", `String
                                                 "Present only when the \
                                                  reset carried code." ]) ] ]

(* Breakpoints. A phrase stops where the caller wrote [%break], and the rest
   of it waits as a value rather than as a blocked process, so the session
   stays usable while it is parked. See docs/wayfinder/tickets/035. *)

let id_arg =
  ("id", `Assoc [ "type", `String "integer";
                  "description", `String "Which parked phrase. Omit when the \
                    session has exactly one, which is the usual case." ])

let continue_tool =
  `Assoc [
    "name", `String "continue";
    "description", `String
      "Resume a phrase parked at a breakpoint, or abandon it. The result is \
       an ordinary evaluation result: what the rest of the phrase printed and \
       what it came to, or another stop if it hit a second breakpoint. \
       Abandon raises inside the phrase instead of resuming it, so the rest \
       does not run but whatever it set up to release on the way out is \
       released.";
    "inputSchema", obj ~required:[]
      [ session_arg; id_arg;
        ("abandon", `Assoc [ "type", `String "boolean";
                             "description", `String "Raise inside the phrase \
                               rather than resuming it." ]) ];
    "outputSchema", obj [ ("phrases", phrase_array);
                          ("status", `Assoc [ "type", `String "string" ]) ] ]

let inspect_tool =
  `Assoc [
    "name", `String "inspect";
    "description", `String
      "Show what the markers have gathered, without resuming anything. The \
       locals of a parked phrase, bound again under their bp_ names, which is \
       how an earlier stop's values are recovered after a later stop \
       overwrote them. And every watch's whole trail, which is what a result \
       does not carry: an eval reports only what its own phrase recorded, \
       while this reports the recent history of each site. Works with nothing \
       parked, as long as something has been watched.";
    "inputSchema", obj [ session_arg; id_arg ];
    "outputSchema", obj
      [ ("id", `Assoc [ "type", `String "integer" ]);
        ("bound", `Assoc [ "type", `String "array";
                           "description", `String "Each local, by the name it \
                             is bound under, with its type." ]);
        ("skipped", `Assoc [ "type", `String "array";
                             "description", `String "Locals that could not be \
                               bound, each with the reason." ]);
        ("phrases", phrase_array) ] ]

(* Source queries. These take a file and a position rather than a session:
   they ask about code as written, not about values in a toplevel, so they
   need nothing loaded and no build. *)

let file_arg =
  ("file", `Assoc [ "type", `String "string";
                    "description", `String "Absolute path to an OCaml source \
                      file in the project." ])

let line_arg =
  ("line", `Assoc [ "type", `String "integer";
                    "description", `String "1-based line." ])

let col_arg =
  ("col", `Assoc [ "type", `String "integer";
                   "description", `String "0-based column." ])

let locate_tool =
  `Assoc [
    "name", `String "locate";
    "description", `String
      "Find where the name at a position is defined. Answers from source, so \
       nothing needs to be built or loaded into a session.";
    "inputSchema", obj ~required:[ "file"; "line"; "col" ]
      [ file_arg; line_arg; col_arg ];
    "outputSchema", obj
      [ ("file", `Assoc [ "type", `String "string" ]);
        ("line", `Assoc [ "type", `String "integer" ]);
        ("col", `Assoc [ "type", `String "integer" ]) ] ]

let type_at_tool =
  `Assoc [
    "name", `String "type_at";
    "description", `String
      "The type of the expression at a position, and of each enclosing \
       expression, innermost first. Answers from source: no build, no load, \
       no session. Enclosings are strictly nested, and exact duplicates from \
       merlin are removed.";
    "inputSchema", obj ~required:[ "file"; "line"; "col" ]
      [ file_arg; line_arg; col_arg ];
    "outputSchema", obj
      [ ("enclosings", `Assoc [ "type", `String "array";
                                "description", `String "Each with type and the \
                                  range it covers, innermost first." ]) ] ]

(* An agent cannot read a generated name off the source in front of it:
   whether [@@deriving yojson] gives to_yojson or yojson_of_t is the deriver's
   choice, and guessing it reads as confident. See tickets/037. *)
(* Not a build, and the description has to say so or it becomes one that lies:
   this types one file against what is already compiled around it, so it will
   not notice that a dependency needs rebuilding. What it can do that nothing
   else here can is answer about an edit that was never written. See
   tickets/042. *)
let diagnostics_tool =
  `Assoc [
    "name", `String "diagnostics";
    "description", `String
      "Errors and warnings for one file, from merlin, in milliseconds and \
       without building anything. Pass source to ask about an edit you have \
       not written to disk yet; the file still has to be named, because that \
       is how the project configuration this is typed against is found. This \
       is not a build: it types one file against what is already compiled \
       around it, so it cannot tell you that a dependency needs rebuilding, \
       and a clean answer here is not a passing build. Warnings come back \
       apart from errors.";
    "inputSchema", obj ~required:[ "file" ]
      [ file_arg;
        ("source", `Assoc
           [ "type", `String "string";
             "description", `String
               "The file's contents as you would write them, typed instead of \
                what is on disk. Positions in the answer are into this text." ]) ];
    "outputSchema", obj
      [ ("errors", `Assoc
           [ "type", `String "array";
             "description", `String
               "Each with its message and the range it covers. Absent when \
                there are none." ]);
        ("warnings", `Assoc
           [ "type", `String "array";
             "description", `String
               "The same shape, kept apart from the errors. Absent when there \
                are none." ]) ] ]

let expand_tool =
  `Assoc [
    "name", `String "expand";
    "description", `String
      "The code a ppx generated at a position: what [@@deriving ...] or a \
       [%extension] expands to, as source. Answers from the file, with no \
       build and no session, so it works on a name that does not exist yet \
       anywhere else. Put the position on the deriver name inside \
       [@@deriving ...], or on the [%extension] itself; a position on the type \
       or expression it is attached to finds nothing. A structure-level \
       extension such as let%test_module may not expand where an expression \
       one does. When the generated names are all you want and the project \
       builds, describe on the built module is cheaper.";
    "inputSchema", obj ~required:[ "file"; "line"; "col" ]
      [ file_arg; line_arg; col_arg ];
    "outputSchema", obj
      [ ("code", `Assoc [ "type", `String "string";
                          "description", `String "The generated source." ]);
        ("deriver", `Assoc
           [ "type", `String "object";
             "description", `String
               "The range of the deriver or extension node this came from." ]);
        ("error", `Assoc
           [ "type", `String "string";
             "description", `String
               "Present instead of code when there is no ppx node at that \
                position, which is an answer about the file rather than a \
                failure." ]) ] ]

let outline_tool =
  `Assoc [
    "name", `String "outline";
    "description", `String
      "What a source file defines: every value, type, module and class, with \
       its kind and position. Cheaper than reading the file when you only \
       need to know what is in it.";
    "inputSchema", obj ~required:[ "file" ] [ file_arg ];
    "outputSchema", obj [ ("items", `Assoc [ "type", `String "array" ]) ] ]

let context_tool =
  `Assoc [
    "name", `String "context";
    "description", `String
      "The opens that put a session in a source file's context, so a fragment \
       lifted out of that file resolves the way the file does. Evaluate the \
       code this returns once, or pass it to reset, and later calls in the \
       session keep it: an open is ordinary session state. Answers from \
       source and needs no session, but the modules it names only exist in a \
       session that has loaded the project. A file that belongs to no wrapped \
       library gets only its own opens, because a session cannot name that \
       file's module.";
    "inputSchema", obj ~required:[ "file" ] [ file_arg ];
    "outputSchema", obj
      [ ("opens", `Assoc [ "type", `String "array";
                           "items", `Assoc [ "type", `String "string" ];
                           "description", `String "The module paths, in the \
                             order they must be opened." ]) ] ]

let uses_tool =
  `Assoc [
    "name", `String "uses";
    "description", `String
      "Every occurrence of the name at a position. Defaults to the whole \
       project rather than the one file, and builds dune's index first if \
       needed, because merlin otherwise answers from this file alone without \
       saying so. If the index cannot be built the result says it is \
       incomplete rather than looking whole.";
    "inputSchema", obj ~required:[ "file"; "line"; "col" ]
      [ file_arg; line_arg; col_arg;
        ("scope", `Assoc [ "type", `String "string";
                           "description", `String "project (the default) or \
                             buffer." ]) ];
    "outputSchema", obj
      [ ("occurrences", `Assoc [ "type", `String "array" ]);
        ("complete", `Assoc [ "type", `String "boolean";
                              "description", `String "Absent when the answer \
                                is project-wide. False, with a caveat, when it \
                                covers only this file." ]);
        ("caveat", `Assoc [ "type", `String "string" ]) ] ]

let search_type_tool =
  `Assoc [
    "name", `String "search_type";
    "description", `String
      "Find values by their type rather than their name, in scope at a \
       position. A query is a type, such as \"int -> string\" or \
       \"'a list -> 'a option\". Qualify type names: merlin matches against \
       its own environment, not the buffer's, so write \"Core.term -> string\" \
       even in a file that opens Core, or the search finds nothing.";
    "inputSchema", obj ~required:[ "file"; "line"; "col"; "query" ]
      [ file_arg; line_arg; col_arg;
        ("query", `Assoc [ "type", `String "string" ]);
        ("limit", `Assoc [ "type", `String "integer" ]) ];
    "outputSchema", obj [ ("results", `Assoc [ "type", `String "array" ]) ] ]

let document_tool =
  `Assoc [
    "name", `String "document";
    "description", `String
      "The documentation comment on a name, as its author wrote it. Answers \
       from source, so nothing needs to be built or loaded. Ask in exactly \
       one of two ways: give identifier for anything in scope in that file, \
       including its dependencies, which is usually what you want; or give \
       line and column for whatever is at that position, which is how to \
       reach a name defined in the file itself. Passing both, or neither, is \
       refused. The text comes back as odoc markup, unrendered: braces such \
       as {!Bytes.t} and {b bold} are the comment's own syntax.";
    "inputSchema", obj ~required:[ "file" ]
      [ file_arg;
        ("identifier", `Assoc [ "type", `String "string";
                                "description", `String "A name in scope in \
                                  that file, such as List.map or \
                                  Yojson.Safe.t. The file supplies the \
                                  environment, and no position is needed or \
                                  accepted with it." ]);
        line_arg; col_arg ];
    "outputSchema", obj
      [ ("documentation", `Assoc [ "type", `String "string";
                                   "description", `String "The comment, in \
                                     odoc markup, verbatim." ]);
        ("error", `Assoc [ "type", `String "string";
                           "description", `String "Present instead of \
                             documentation when there is none, or when the \
                             name is not in scope in that file." ]) ] ]

let signature_tool =
  `Assoc [
    "name", `String "signature";
    "description", `String
      "Show the signature of a module, value or type in an installed findlib \
       package, without loading it. Answers from the package's compiled \
       interfaces, so no session is needed, nothing is linked and none of the \
       package's code runs. Use describe instead for what a session already \
       has, and for modules defined during the session.";
    "inputSchema", obj ~required:[ "path" ]
      [ ("path", `Assoc [ "type", `String "string";
                          "description", `String "A module path such as \
                            Lwt.Infix, or a value such as Lwt.bind." ]);
        ("package", `Assoc [ "type", `String "string";
                             "description", `String "The findlib package \
                               holding it, such as lwt.unix. Omit when the \
                               package is named after the first component of \
                               the path, which is the usual case." ]) ];
    "outputSchema", obj
      [ ("signature", `Assoc [ "type", `String "string";
                               "description", `String "What the toplevel \
                                 prints for the path, as #show would." ]);
        ("package", `Assoc [ "type", `String "string";
                             "description", `String "The package that was \
                               searched, guessed or given." ]);
        ("guessed", `Assoc [ "type", `String "boolean";
                             "description", `String "True when the package \
                               was guessed from the path rather than given. \
                               A failure with this set is worth retrying with \
                               the package named; one without it is not." ]);
        ("error", `Assoc [ "type", `String "string";
                           "description", `String "Present instead of \
                             signature when the package or the path was not \
                             found." ]) ] ]

let all =
  [ eval_tool; describe_tool; require_tool; load_tool; reset_tool;
    continue_tool; inspect_tool;
    locate_tool; type_at_tool; outline_tool; uses_tool; search_type_tool;
    expand_tool; diagnostics_tool; markers_tool;
    document_tool; signature_tool; context_tool ]
