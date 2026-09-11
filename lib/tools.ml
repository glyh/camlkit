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
               "description", `String "What the phrase printed." ] ] ]

let eval_tool =
  `Assoc [
    "name", `String "eval";
    "description", `String
      "Evaluate OCaml phrases in a session. Accepts several phrases in one \
       call. Nothing is executed unless every phrase parses and typechecks, \
       so a failure never leaves partial state behind. One consequence worth \
       knowing: a phrase that changes the search path, such as one calling \
       Topdirs.dir_directory, cannot be used by a later phrase in the same \
       call, because that later phrase is typechecked before anything runs. \
       Put the path change in its own call. Directives such as #require are \
       not accepted here; use the require and describe tools.";
    "inputSchema", obj ~required:[ "session"; "code" ]
      [ session_arg;
        ("code", `Assoc [ "type", `String "string";
                          "description", `String "OCaml source. Phrases are \
                            terminated with ;; as usual." ]) ];
    "outputSchema", obj [ ("phrases", `Assoc [ "type", `String "array";
                                               "items", phrase_schema ]) ] ]

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
       a new session name, which leaves the old toplevel running.";
    "inputSchema", obj ~required:[ "session" ] [ session_arg ];
    "outputSchema", obj [ ("status", `Assoc [ "type", `String "string" ]) ] ]

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

let build_tool =
  `Assoc [
    "name", `String "build";
    "description", `String
      "Build a dune project and report its errors and warnings, each with a \
       file, line, column and severity, alongside dune's own output verbatim. \
       Point it at the project root. After a successful build, reload a \
       session with the load tool and reset set, or the session keeps running \
       the old code.";
    "inputSchema", obj ~required:[ "path" ]
      [ ("path", `Assoc [ "type", `String "string";
                          "description", `String "Project root, the directory \
                            holding dune-project." ]);
        ("targets", `Assoc [ "type", `String "array";
                             "items", `Assoc [ "type", `String "string" ];
                             "description", `String "Dune targets or aliases. \
                               Defaults to the whole project." ]) ];
    "outputSchema", obj
      [ ("status", `Assoc [ "type", `String "string";
                            "description", `String "success or failure." ]);
        ("diagnostics", `Assoc [ "type", `String "array";
                                 "items", obj
                                   [ ("severity", `Assoc [ "type", `String "string" ]);
                                     ("file", `Assoc [ "type", `String "string" ]);
                                     ("line", `Assoc [ "type", `String "integer" ]);
                                     ("col", `Assoc [ "type", `String "integer" ]);
                                     ("message", `Assoc [ "type", `String "string" ]) ] ]);
        ("output", `Assoc [ "type", `String "string";
                            "description", `String "Everything dune said, \
                              verbatim. This is the whole answer when a \
                              failure has no located diagnostic: a bad \
                              target, a dune file error, a missing \
                              dependency." ]) ] ]

let all =
  [ eval_tool; describe_tool; require_tool; load_tool; reset_tool; build_tool;
    locate_tool; type_at_tool; outline_tool; uses_tool; search_type_tool ]
