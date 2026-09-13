(* MCP tool declarations. Each carries an outputSchema so results arrive as
   structuredContent rather than as prose the agent must re-parse: the worker
   already separates the toplevel's rendering from program output, warnings
   and error spans, and flattening that would throw the structure away.

   A description is a trigger: when to reach for the tool, and the one mistake
   that would make a call wrong. It is loaded with the tool whether or not the
   tool is used, so everything else lives in Guide and is read through help.
   See docs/wayfinder/tickets/062. *)

let str d = `Assoc [ "type", `String "string"; "description", `String d ]
let int d = `Assoc [ "type", `String "integer"; "description", `String d ]
let bool d = `Assoc [ "type", `String "boolean"; "description", `String d ]
let typed t = `Assoc [ "type", `String t ]
let list ?description item =
  `Assoc ([ "type", `String "array"; "items", `Assoc [ "type", `String item ] ]
          @ match description with
          | Some d -> [ "description", `String d ] | None -> [])
let array = typed "array"

let tool ~name ?(required = []) description inputs outputs =
  let obj props =
    `Assoc [ "type", `String "object";
             "properties", `Assoc props;
             "required", `List (List.map (fun r -> `String r) required) ] in
  `Assoc [ "name", `String name;
           "description",
           `String (if name = "help" then description
                    else description ^ " Manual: help " ^ name ^ ".");
           "inputSchema", obj inputs;
           "outputSchema",
           `Assoc [ "type", `String "object"; "properties", `Assoc outputs;
                    "required", `List [] ] ]

let session_arg = ("session", str "Session name, default main.")

(* Every field is absent when it has nothing to say. What each means is in the
   eval manual. *)
let phrase_array =
  `Assoc [ "type", `String "array";
           "items", `Assoc [ "type", `String "object";
                             "properties", `Assoc [
                               "rendering", typed "string";
                               "warnings", typed "string";
                               "output", typed "string";
                               "ran", typed "string";
                               "watched", array;
                               "cost", typed "object" ] ] ]

let status = ("status", typed "string")
let loaded = [ ("loaded", list "string"); ("failed", array) ]

let eval_tool =
  tool ~name:"eval" ~required:[ "code" ]
    "Run OCaml in a persistent session: try code, see a value, check a type. \
     Every phrase must typecheck or none run, and #directives are rejected. \
     [%break], [%watch] and [%swap] debug live code."
    [ session_arg;
      ("code", str "OCaml phrases, each ending in ;;.");
      ("check", bool "Typecheck only; nothing runs.");
      ("cost", bool "Report time and allocation per phrase.");
      ("autorun", list "string"
         ~description:"Promise libraries whose bare promises are run; [] \
                       returns the promise.") ]
    [ ("phrases", phrase_array); ("autorun", list "string");
      ("checked", typed "boolean") ]

let describe_tool =
  tool ~name:"describe" ~required:[ "path" ]
    "Show the signature of a module, value or type a session has. Prefer it \
     to guessing at names."
    [ session_arg; ("path", str "Such as List or List.map.") ]
    [ ("phrases", phrase_array); ("error", typed "string") ]

let require_tool =
  tool ~name:"require" ~required:[ "packages" ]
    "Load findlib packages into a session."
    [ session_arg; ("packages", list "string") ]
    (status :: loaded)

let load_tool =
  tool ~name:"load"
    "Load a dune project's own libraries into a session. Pass reset after \
     rebuilding."
    [ session_arg;
      ("path", str "Project root; defaults to the server's project.");
      ("libraries", list "string" ~description:"Omit to load all.");
      ("reset", bool "Empty the session first.") ]
    (status :: loaded)

let reset_tool =
  tool ~name:"reset"
    "Empty a session back to a clean toplevel, optionally running code in it."
    [ session_arg; ("code", str "Evaluated in the fresh toplevel.") ]
    [ status; ("phrases", phrase_array) ]

let id_arg = ("id", int "Parked phrase; omit when there is one.")

let continue_tool =
  tool ~name:"continue"
    "Resume or abandon a phrase parked at [%break]."
    [ session_arg; id_arg;
      ("abandon", bool "Raise inside the phrase instead of resuming.") ]
    [ ("phrases", phrase_array); status ]

let inspect_tool =
  tool ~name:"inspect"
    "See a parked phrase's locals and every watch's recorded values, without \
     resuming."
    [ session_arg; id_arg ]
    [ ("id", typed "integer"); ("bound", array); ("skipped", array);
      ("phrases", phrase_array) ]

(* A marker is compiled into the code holding it, so it fires whenever that
   code runs. This is what stops one. See docs/wayfinder/tickets/049. *)
let markers_tool =
  tool ~name:"markers"
    "List, arm and disarm a session's breakpoints and watches; restore \
     swapped functions."
    [ session_arg;
      ("disarm", list "string" ~description:"Names to turn off.");
      ("arm", list "string" ~description:"Names to turn on.");
      ("disarm_sites", list "integer" ~description:"Site ids to turn off.");
      ("arm_sites", list "integer" ~description:"Site ids to turn on.");
      ("restore", list "string" ~description:"Swapped paths to put back.") ]
    [ ("markers", array); ("swapped", list "string");
      ("unknown", list "string") ]

let all =
  [ eval_tool; describe_tool; require_tool; load_tool; reset_tool;
    continue_tool; inspect_tool; markers_tool ]
