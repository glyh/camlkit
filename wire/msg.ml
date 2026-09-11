(* Request and response types crossing the server/worker boundary.
   Metadata rides in the JSON segment; captured program output is the raw
   segment, addressed by per-phrase offsets. *)

type request =
  | Eval of string          (* OCaml phrases; directives are rejected *)
  | Describe of string      (* a module path, answered via #show *)
  | Require of string list  (* findlib packages *)
  (* A dune build tree, whose private libraries findlib cannot see. *)
  | Load of { path : string; libraries : string list;
              (* findlib packages to load first. A reset empties the session,
                 including anything it had required, and a project's libraries
                 usually need some of those to load at all. *)
              packages : string list }

(* One record per phrase. [rendering] is the toplevel's own output, such as
   "val x : int = 42"; program output lives in the raw segment at
   [out_start, out_start + out_len). These are different questions and the
   first worker prototype wrongly concatenated them. *)
(* What the toplevel produced, as data rather than as the sentence it prints.
   "val _0 : int = 42" packs a name, a type and a value into one string, and
   the type is the thing a caller most often wants. *)
(* Name and type only. The value is deliberately absent: it duplicates the
   rendering exactly, and it is a printed representation rather than data -
   "<fun>", "<abstr>", or a list the printer elided. Measured at two to four
   times the rendering's size before it was dropped. *)
type binding = {
  bound : string;         (* the name, or "" where the item has none *)
  bound_kind : string;    (* value, type, module, modtype, class, exception *)
  bound_type : string;    (* its type, or the whole declaration for a type *)
}

type outcome =
  | No_outcome                                   (* the phrase printed nothing *)
  | Value of { value_type : string }             (* a bare expression *)
  | Bindings of binding list                     (* let, type, module, ... *)
  | Raised of string                             (* an uncaught exception *)

type phrase = {
  rendering : string;
  warnings : string;
  out_start : int;
  out_len : int;
  truncated : bool;   (* this phrase printed more than the cap allowed *)
  outcome : outcome;  (* the rendering, decomposed *)
}

type phase = Parse | Typecheck | Execute

type failure = {
  phase : phase;
  phrase_index : int;        (* -1 when the whole buffer failed to parse *)
  message : string;
  spans : (int * int) list;  (* byte offsets into the submitted source *)
  lines : (int * int) list;  (* the same errors as line ranges *)
  (* Phrases that ran before this one. Empty for a parse or typecheck
     failure, where nothing runs, but not for a runtime failure: those
     phrases really did execute and their output is worth keeping. *)
  done_ : phrase list;
}

type response =
  | Completed of phrase list
  (* Loading is not a phrase result and should not pretend to be one: a caller
     wants the library names as data, not a sentence to parse. *)
  | Loaded of { loaded : string list; failed : (string * string) list }
  | Failed of failure
  | Interrupted of { phrase_index : int; done_ : phrase list }
  | Rejected of string       (* e.g. a directive sent to eval *)

let string_of_phase = function
  | Parse -> "parse" | Typecheck -> "typecheck" | Execute -> "execute"

let phase_of_string = function
  | "parse" -> Parse | "typecheck" -> Typecheck | "execute" -> Execute
  | s -> failwith ("unknown phase: " ^ s)

let json_of_request = function
  | Eval src -> `Assoc [ "kind", `String "eval"; "source", `String src ]
  | Describe p -> `Assoc [ "kind", `String "describe"; "path", `String p ]
  | Require ps ->
    `Assoc [ "kind", `String "require";
             "packages", `List (List.map (fun p -> `String p) ps) ]
  | Load { path; libraries; packages } ->
    `Assoc [ "kind", `String "load"; "path", `String path;
             "libraries", `List (List.map (fun l -> `String l) libraries);
             "packages", `List (List.map (fun p -> `String p) packages) ]

let request_of_json j =
  let open Yojson.Safe.Util in
  match member "kind" j |> to_string with
  | "eval" -> Eval (member "source" j |> to_string)
  | "describe" -> Describe (member "path" j |> to_string)
  | "require" -> Require (member "packages" j |> to_list |> List.map to_string)
  | "load" ->
    Load { path = member "path" j |> to_string;
           libraries = (match member "libraries" j with
               | `List l -> List.map to_string l | _ -> []);
           packages = (match member "packages" j with
               | `List l -> List.map to_string l | _ -> []) }
  | k -> failwith ("unknown request kind: " ^ k)

(* A phrase can print without bound, and an MCP result is a single payload with
   no streaming, so captured output is capped. The limit is small because the
   result lands in a model's context: 16K of text is already about four
   thousand tokens, and a half-megabyte result overflows a tool-result limit
   and spills to a file, which helps nobody.
   Clamping is pure so it can be tested without running a toplevel.
   ponytail: one fixed limit; make it per-request if anyone needs more. *)
let output_limit = 16 * 1024

let clamp ~limit phrases =
  let any = ref false in
  let clamp_one p =
    if p.out_len <= 0 then p                       (* nothing to cut *)
    else if p.out_start >= limit then (any := true;
      { p with out_start = limit; out_len = 0; truncated = true })
    else if p.out_start + p.out_len > limit then (any := true;
      { p with out_len = limit - p.out_start; truncated = true })
    else p
  in
  let clamped = List.map clamp_one phrases in
  (clamped, !any)

let json_of_binding { bound; bound_kind; bound_type } =
  `Assoc [ "name", `String bound; "kind", `String bound_kind;
           "type", `String bound_type ]

let json_of_outcome = function
  | No_outcome -> `Assoc [ "kind", `String "nothing" ]
  | Value { value_type } -> `Assoc [ "kind", `String "value";
                                     "type", `String value_type ]
  | Bindings bs ->
    `Assoc [ "kind", `String "bindings";
             "items", `List (List.map json_of_binding bs) ]
  | Raised e -> `Assoc [ "kind", `String "exception"; "exception", `String e ]

let outcome_of_json j =
  let open Yojson.Safe.Util in
  match member "kind" j |> to_string with
  | "value" -> Value { value_type = member "type" j |> to_string }
  | "bindings" ->
    Bindings (member "items" j |> to_list
              |> List.map (fun b ->
                  { bound = member "name" b |> to_string;
                    bound_kind = (match member "kind" b with
                        | `String k -> k | _ -> "value");
                    bound_type = member "type" b |> to_string }))
  | "exception" -> Raised (member "exception" j |> to_string)
  | _ -> No_outcome

let json_of_phrase { rendering; warnings; out_start; out_len; truncated; outcome } =
  `Assoc [ "rendering", `String rendering; "warnings", `String warnings;
           "out_start", `Int out_start; "out_len", `Int out_len;
           "truncated", `Bool truncated; "outcome", json_of_outcome outcome ]

let phrase_of_json j =
  let open Yojson.Safe.Util in
  { rendering = member "rendering" j |> to_string;
    warnings = member "warnings" j |> to_string;
    out_start = member "out_start" j |> to_int;
    out_len = member "out_len" j |> to_int;
    truncated = member "truncated" j |> to_bool;
    outcome = outcome_of_json (member "outcome" j) }

let json_of_response = function
  | Completed ps ->
    `Assoc [ "status", `String "completed";
             "phrases", `List (List.map json_of_phrase ps) ]
  | Failed { phase; phrase_index; message; spans; lines; done_ } ->
    `Assoc [ "status", `String "failed";
             "phase", `String (string_of_phase phase);
             "phrase_index", `Int phrase_index;
             "message", `String message;
             "spans", `List (List.map (fun (a, b) -> `List [ `Int a; `Int b ]) spans);
             "lines", `List (List.map (fun (a, b) -> `List [ `Int a; `Int b ]) lines);
             "phrases", `List (List.map json_of_phrase done_) ]
  | Interrupted { phrase_index; done_ } ->
    `Assoc [ "status", `String "interrupted";
             "phrase_index", `Int phrase_index;
             "phrases", `List (List.map json_of_phrase done_) ]
  | Loaded { loaded; failed } ->
    `Assoc [ "status", `String (if failed = [] then "ok" else "partial");
             "loaded", `List (List.map (fun l -> `String l) loaded);
             "failed", `List (List.map (fun (lib, err) ->
                 `Assoc [ "library", `String lib; "error", `String err ]) failed) ]
  | Rejected why -> `Assoc [ "status", `String "rejected"; "reason", `String why ]

let response_of_json j =
  let open Yojson.Safe.Util in
  match member "status" j |> to_string with
  | "completed" -> Completed (member "phrases" j |> to_list |> List.map phrase_of_json)
  | "failed" ->
    Failed { phase = member "phase" j |> to_string |> phase_of_string;
             phrase_index = member "phrase_index" j |> to_int;
             message = member "message" j |> to_string;
             spans = member "spans" j |> to_list
                     |> List.map (fun s -> match to_list s with
                         | [ a; b ] -> (to_int a, to_int b)
                         | _ -> failwith "bad span");
             lines = member "lines" j |> to_list
                     |> List.map (fun s -> match to_list s with
                         | [ a; b ] -> (to_int a, to_int b)
                         | _ -> failwith "bad line range");
             done_ = (match member "phrases" j with
                 | `List ps -> List.map phrase_of_json ps
                 | _ -> []) }
  | "interrupted" ->
    Interrupted { phrase_index = member "phrase_index" j |> to_int;
                  done_ = member "phrases" j |> to_list |> List.map phrase_of_json }
  | "ok" | "partial" ->
    Loaded { loaded = member "loaded" j |> to_list |> List.map to_string;
             failed = member "failed" j |> to_list
                      |> List.map (fun f ->
                          (member "library" f |> to_string,
                           member "error" f |> to_string)) }
  | "rejected" -> Rejected (member "reason" j |> to_string)
  | s -> failwith ("unknown status: " ^ s)
