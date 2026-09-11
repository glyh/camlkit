(* Request and response types crossing the server/worker boundary.
   Metadata rides in the JSON segment; captured program output is the raw
   segment, addressed by per-phrase offsets. *)

type request =
  | Eval of string          (* OCaml phrases; directives are rejected *)
  | Describe of string      (* a module path, answered via #show *)
  | Require of string list  (* findlib packages *)

(* One record per phrase. [rendering] is the toplevel's own output, such as
   "val x : int = 42"; program output lives in the raw segment at
   [out_start, out_start + out_len). These are different questions and the
   first worker prototype wrongly concatenated them. *)
type phrase = {
  rendering : string;
  warnings : string;
  out_start : int;
  out_len : int;
  truncated : bool;   (* this phrase printed more than the cap allowed *)
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

let request_of_json j =
  let open Yojson.Safe.Util in
  match member "kind" j |> to_string with
  | "eval" -> Eval (member "source" j |> to_string)
  | "describe" -> Describe (member "path" j |> to_string)
  | "require" -> Require (member "packages" j |> to_list |> List.map to_string)
  | k -> failwith ("unknown request kind: " ^ k)

(* A phrase can print without bound and an MCP result is a single payload with
   no streaming, so captured output is capped. Clamping is pure so it can be
   tested without running a toplevel.
   ponytail: one fixed limit; make it per-request if anyone needs more. *)
let output_limit = 4 * 1024 * 1024

let clamp ~limit phrases =
  let any = ref false in
  let clamp_one p =
    if p.out_start >= limit then (any := true;
      { p with out_start = limit; out_len = 0; truncated = true })
    else if p.out_start + p.out_len > limit then (any := true;
      { p with out_len = limit - p.out_start; truncated = true })
    else p
  in
  let clamped = List.map clamp_one phrases in
  (clamped, !any)

let json_of_phrase { rendering; warnings; out_start; out_len; truncated } =
  `Assoc [ "rendering", `String rendering; "warnings", `String warnings;
           "out_start", `Int out_start; "out_len", `Int out_len;
           "truncated", `Bool truncated ]

let phrase_of_json j =
  let open Yojson.Safe.Util in
  { rendering = member "rendering" j |> to_string;
    warnings = member "warnings" j |> to_string;
    out_start = member "out_start" j |> to_int;
    out_len = member "out_len" j |> to_int;
    truncated = member "truncated" j |> to_bool }

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
  | "rejected" -> Rejected (member "reason" j |> to_string)
  | s -> failwith ("unknown status: " ^ s)
