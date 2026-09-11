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
             "rendering", `Assoc [ "type", `String "string";
               "description", `String "The toplevel's own output, e.g. \
                 \"val x : int = 42\"." ];
             "warnings", `Assoc [ "type", `String "string" ];
             "output", `Assoc [ "type", `String "string";
               "description", `String "What the phrase printed." ] ] ]

let eval_tool =
  `Assoc [
    "name", `String "eval";
    "description", `String
      "Evaluate OCaml phrases in a session. Accepts several phrases in one \
       call. Nothing is executed unless every phrase parses and typechecks, \
       so a failure never leaves partial state behind. Directives such as \
       #require are not accepted here; use the require and describe tools.";
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
    "outputSchema", obj [ ("phrases", phrase_array) ] ]

let reset_tool =
  `Assoc [
    "name", `String "reset";
    "description", `String
      "Discard a session and start it clean. Its bindings and loaded packages \
       are gone. Use this to get back to a known state rather than inventing \
       a new session name, which leaves the old toplevel running.";
    "inputSchema", obj ~required:[ "session" ] [ session_arg ];
    "outputSchema", obj [ ("status", `Assoc [ "type", `String "string" ]) ] ]

let all = [ eval_tool; describe_tool; require_tool; reset_tool ]
