(* MCP tool declarations. Each carries an outputSchema so results arrive as
   structuredContent rather than as prose the agent must re-parse: the worker
   already separates the toplevel's rendering from program output, warnings
   and error spans, and flattening that would throw the structure away. *)

let session_arg =
  ("session", `Assoc [ "type", `String "string";
                       "description", `String "Session name. Sessions are \
                         independent toplevels; state persists between calls." ])

let obj ?(required = []) props =
  `Assoc [ "type", `String "object";
           "properties", `Assoc props;
           "required", `List (List.map (fun r -> `String r) required) ]

let phrase_schema =
  `Assoc [ "type", `String "object";
           "properties", `Assoc [
             "bindings", `Assoc [ "type", `String "array";
               "description", `String "What the phrase bound, one entry per \
                 name, each with its name and type. A module's type is its \
                 signature. Empty for a phrase that bound nothing." ];
             "rendering", `Assoc [ "type", `String "string";
               "description", `String "What the toplevel printed about the \
                 phrase, verbatim: bindings with their types and values, as a \
                 utop transcript." ];
             "warnings", `Assoc [ "type", `String "string" ];
             "output", `Assoc [ "type", `String "string";
               "description", `String "What the phrase printed." ];
             "ran", `Assoc [ "type", `String "string";
               "description", `String "The autorun rule that rewrote this \
                 phrase, if one did: the expression was a promise and was run \
                 rather than returned. Absent when nothing was rewritten." ] ] ]

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
       tools, and showing a signature is describe. Write [%break] in a phrase \
       to stop there and inspect it, then continue.";
    "inputSchema", obj ~required:[ "session"; "code" ]
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
                itself instead." ]) ];
    "outputSchema", obj [ ("phrases", `Assoc [ "type", `String "array";
                                               "items", phrase_schema ]);
                          ("autorun", `Assoc
                             [ "type", `String "array";
                               "items", `Assoc [ "type", `String "string" ];
                               "description", `String
                                 "The rules this call ran under. A rewrite is \
                                  otherwise invisible, since a run promise \
                                  renders like any value." ]) ] ]

let phrase_array =
  `Assoc [ "type", `String "array"; "items", phrase_schema ]

let describe_tool =
  `Assoc [
    "name", `String "describe";
    "description", `String
      "Show the signature of a module, value or type in a session, including \
       modules defined during the session. Prefer this over guessing at names.";
    "inputSchema", obj ~required:[ "session"; "path" ]
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
    "inputSchema", obj ~required:[ "session"; "packages" ]
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
    "inputSchema", obj ~required:[ "session"; "path" ]
      [ session_arg;
        ("path", `Assoc [ "type", `String "string";
                          "description", `String "Project root, or a \
                            directory inside its _build tree." ]);
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
    "inputSchema", obj ~required:[ "session" ]
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
    "inputSchema", obj ~required:[ "session" ]
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
      "Show the locals of a parked phrase and bind them again under their \
       bp_ names. A stop already binds them, so this is for reading them once \
       more, and for getting an earlier stop's values back after a later stop \
       overwrote the names. It does not resume anything.";
    "inputSchema", obj ~required:[ "session" ] [ session_arg; id_arg ];
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

let outline_tool =
  `Assoc [
    "name", `String "outline";
    "description", `String
      "What a source file defines: every value, type, module and class, with \
       its kind and position. Cheaper than reading the file when you only \
       need to know what is in it.";
    "inputSchema", obj ~required:[ "file" ] [ file_arg ];
    "outputSchema", obj [ ("items", `Assoc [ "type", `String "array" ]) ] ]

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
    document_tool; signature_tool ]
