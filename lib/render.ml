(* Functional core: turning a worker response into an MCP tool result.

   isError is reserved for infrastructure failure, per
   docs/wayfinder/tickets/002. A phrase that fails to typecheck is a
   successful evaluation whose verdict is negative, so it comes back as an
   ordinary result; isError means the server failed at its own job. *)

open Wire

type t = {
  content : string;
  structured : Yojson.Safe.t;
  is_error : bool;
}

(* Spans are clamped by the worker before sending, so this cannot read past
   the payload; it stays defensive because a mismatch would be silent. *)
let slice payload (p : Msg.phrase) =
  let n = String.length payload in
  if p.out_len <= 0 || p.out_start < 0 || p.out_start > n then ""
  else String.sub payload p.out_start (min p.out_len (n - p.out_start))

let json_phrase payload (p : Msg.phrase) =
  `Assoc [ "rendering", `String p.rendering;
           "warnings", `String p.warnings;
           "output", `String (slice payload p);
           "truncated", `Bool p.truncated ]

(* A transcript, in the order a terminal would show it: warnings, then what
   the phrase printed, then what the toplevel made of it. *)
let transcript payload phrases =
  let buf = Buffer.create 256 in
  List.iter (fun (p : Msg.phrase) ->
      if p.warnings <> "" then Buffer.add_string buf (String.trim p.warnings ^ "\n");
      let out = slice payload p in
      if out <> "" then Buffer.add_string buf out;
      if p.truncated then
        Buffer.add_string buf "\n[output truncated: the phrase printed more \
                               than the limit]\n";
      if p.rendering <> "" then Buffer.add_string buf (String.trim p.rendering ^ "\n"))
    phrases;
  Buffer.contents buf

let spans_json spans =
  `List (List.map (fun (a, b) -> `List [ `Int a; `Int b ]) spans)

let of_response (response : Msg.response) payload =
  match response with
  | Msg.Completed phrases ->
    { content = (match transcript payload phrases with "" -> "(no output)" | s -> s);
      structured = `Assoc [ "status", `String "ok";
                            "phrases", `List (List.map (json_phrase payload) phrases) ];
      is_error = false }
  | Msg.Failed f ->
    let where =
      if f.phrase_index < 0 then "the submitted source did not parse"
      else Printf.sprintf "phrase %d failed at %s"
          (f.phrase_index + 1) (Msg.string_of_phase f.phase)
    in
    (* The message arrives with its location prefix stripped, so put the
       location back for the human-readable half. *)
    let at = match f.lines, f.spans with
      | (a, b) :: _, _ when a = b -> Printf.sprintf " (line %d)" a
      | (a, b) :: _, _ -> Printf.sprintf " (lines %d-%d)" a b
      | [], (a, b) :: _ when b > a -> Printf.sprintf " (characters %d-%d)" a b
      | _ -> ""
    in
    (* "Nothing ran" is true of a parse or typecheck failure, where the whole
       request is rejected before execution, and false of a runtime one. *)
    let aftermath = match f.phase with
      | Msg.Parse | Msg.Typecheck -> "Nothing was executed."
      | Msg.Execute ->
        if f.phrase_index <= 0 then "Nothing before it ran."
        else Printf.sprintf "The %d phrase%s before it did run."
            f.phrase_index (if f.phrase_index = 1 then "" else "s")
    in
    let before = transcript payload f.done_ in
    { content = Printf.sprintf "%s%s%s\n\n%s\n\n%s"
          before where at (String.trim f.message) aftermath;
      structured = `Assoc [ "status", `String "failed";
                            "phase", `String (Msg.string_of_phase f.phase);
                            "phrase", `Int (f.phrase_index + 1);
                            "message", `String f.message;
                            "spans", spans_json f.spans;
                            "lines", spans_json f.lines;
                            "phrases", `List (List.map (json_phrase payload) f.done_) ];
      is_error = false }
  | Msg.Interrupted { phrase_index; done_ } ->
    { content = Printf.sprintf
          "%s\nPhrase %d ran past the time limit and was interrupted. The \
           session is still usable and its earlier bindings are intact."
          (transcript payload done_) (phrase_index + 1);
      structured = `Assoc [ "status", `String "interrupted";
                            "phrase", `Int (phrase_index + 1);
                            "phrases", `List (List.map (json_phrase payload) done_) ];
      is_error = false }
  | Msg.Loaded { loaded; failed } ->
    let plural n = if n = 1 then "y" else "ies" in
    let summary =
      Printf.sprintf "loaded %d librar%s%s" (List.length loaded)
        (plural (List.length loaded))
        (match loaded with [] -> "" | ls -> ": " ^ String.concat ", " ls)
    in
    let detail =
      match failed with
      | [] -> ""
      | fs ->
        "\n\nnot loaded:\n"
        ^ String.concat "\n"
            (List.map (fun (lib, err) -> Printf.sprintf "%s: %s" lib err) fs)
    in
    { content = summary ^ detail;
      structured =
        `Assoc [ "status", `String (if failed = [] then "ok" else "partial");
                 "loaded", `List (List.map (fun l -> `String l) loaded);
                 "failed", `List (List.map (fun (lib, err) ->
                     `Assoc [ "library", `String lib; "error", `String err ])
                     failed) ];
      is_error = false }
  | Msg.Rejected why ->
    { content = why;
      structured = `Assoc [ "status", `String "rejected"; "reason", `String why ];
      is_error = false }

(* A session that had to be restarted comes back empty. Say so on the first
   result afterwards rather than letting an agent assume its bindings survived.
   ponytail: one note on one result; if agents start missing it, make the
   restart its own structured status. *)
let with_note note t =
  { t with
    content = note ^ "\n\n" ^ t.content;
    structured = (match t.structured with
        | `Assoc fields -> `Assoc (("note", `String note) :: fields)
        | other -> other) }

(* The server failing at its own job, as opposed to a phrase failing, which is
   an ordinary result above. *)
let infrastructure_failure message =
  { content = message;
    structured = `Assoc [ "status", `String "error"; "message", `String message ];
    is_error = true }
