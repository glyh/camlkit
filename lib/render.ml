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

(* A field that says nothing is not worth its bytes: a result lands in a
   model's context, where every empty string and every false flag is paid for
   in tokens. So an empty rendering, no output, no warnings and no bindings
   are simply absent, as [ran] already was, and truncation is folded into the
   output it qualifies rather than carried as a flag beside it. *)
let field name = function "" -> [] | s -> [ (name, `String s) ]

(* Readable rather than exact: three significant figures is more than a single
   un-repeated run in a toplevel can honestly support. *)
let millis ms =
  if ms >= 100. then Printf.sprintf "%.0f ms" ms
  else if ms >= 1. then Printf.sprintf "%.1f ms" ms
  else Printf.sprintf "%.2f ms" ms

let bytes n =
  let f = float_of_int n in
  if n >= 1_000_000_000 then Printf.sprintf "%.1f GB" (f /. 1e9)
  else if n >= 1_000_000 then Printf.sprintf "%.1f MB" (f /. 1e6)
  else if n >= 1_000 then Printf.sprintf "%.1f kB" (f /. 1e3)
  else Printf.sprintf "%d B" n

(* Where a site is written, as fields: which definition, which line of the call
   that sent it, and the watched text. *)
let at_fields (a : Msg.at) =
  (match a.Msg.in_def with None -> [] | Some d -> [ ("in", `String d) ])
  @ [ ("line", `Int a.Msg.line) ]
  @ field "code" a.Msg.code

let at_text (a : Msg.at) =
  Printf.sprintf "%sline %d%s"
    (match a.Msg.in_def with None -> "" | Some d -> "in " ^ d ^ ", ")
    a.Msg.line
    (if a.Msg.code = "" then "" else ": " ^ a.Msg.code)

let json_phrase payload (p : Msg.phrase) =
  let out = slice payload p in
  let out =
    if p.dropped > 0 then
      Printf.sprintf "%s\n[output truncated, %d more character%s]" out p.dropped
        (if p.dropped = 1 then "" else "s")
    else out
  in
  `Assoc
    (field "rendering" p.rendering
     @ field "warnings" p.warnings
     @ field "output" out
     @ (match p.ran with None -> [] | Some r -> [ ("ran", `String r) ])
     @ (match p.watched with
         | [] -> []
         | ws ->
           [ ("watched",
              `List (List.map (fun (w : Msg.watched) ->
                  `Assoc ([ ("name", `String w.Msg.site);
                            ("id", `Int w.Msg.site_id) ]
                          @ at_fields w.Msg.at
                          @ [ ("hits", `Int w.Msg.site_hits);
                              ("values",
                               `List (List.map (fun v -> `String v)
                                        w.Msg.values)) ]))
                  ws)) ])
     @ (match p.cost with
         | None -> []
         | Some c ->
           [ ("cost",
              `Assoc [ ("wall_ms", `Float (Float.round (c.wall_ms *. 1000.) /. 1000.));
                       ("allocated_bytes", `Int c.allocated_bytes) ]) ]))

(* A transcript, in the order a terminal would show it: warnings, then what
   the phrase printed, then what the toplevel made of it. *)
let transcript payload phrases =
  let buf = Buffer.create 256 in
  List.iter (fun (p : Msg.phrase) ->
      if p.warnings <> "" then Buffer.add_string buf (String.trim p.warnings ^ "\n");
      let out = slice payload p in
      if out <> "" then Buffer.add_string buf out;
      if p.dropped > 0 then
        Buffer.add_string buf
          (Printf.sprintf "\n[output truncated, %d more character%s]\n" p.dropped
             (if p.dropped = 1 then "" else "s"));
      if p.rendering <> "" then Buffer.add_string buf (String.trim p.rendering ^ "\n");
      (* The rewrite is otherwise invisible here: the transcript of a promise
         that was run looks exactly like one of a plain value. *)
      (match p.ran with
       | None -> ()
       | Some rule ->
         Buffer.add_string buf
           (Printf.sprintf "[autorun %s: the expression was run, not returned \
                            as a promise]\n" rule));
      (* A watch prints nothing of its own while it runs, so without this the
         transcript would show a phrase that recorded a thousand values as one
         that did nothing. The lifetime count is beside this phrase's values
         because the two answer different questions. *)
      List.iter
        (fun (w : Msg.watched) ->
           Buffer.add_string buf
             (Printf.sprintf "[watch %S #%d (%s): %s%s]\n" w.Msg.site
                w.Msg.site_id (at_text w.Msg.at)
                (String.concat ", " w.Msg.values)
                (if w.Msg.site_hits > List.length w.Msg.values then
                   Printf.sprintf " (%d hits in all)" w.Msg.site_hits
                 else "")))
        p.watched;
      (* Only when the call asked. A phrase that allocated nothing still says
         so, because zero is the answer to "did this allocate" and absence
         would read as the measurement having been skipped. *)
      match p.cost with
      | None -> ()
      | Some c ->
        Buffer.add_string buf
          (Printf.sprintf "[%s, %s allocated]\n" (millis c.wall_ms)
             (bytes c.allocated_bytes)))
    phrases;
  Buffer.contents buf

let spans_json spans =
  `List (List.map (fun (a, b) -> `List [ `Int a; `Int b ]) spans)

let of_response (response : Msg.response) payload =
  match response with
  | Msg.Completed { phrases; autorun; checked } ->
    let transcript = match transcript payload phrases with
      | "" -> "(no output)" | s -> s in
    { content =
        (* Said rather than left to be inferred from an absent "= value": the
           whole point of the call is that this is what would happen, not what
           did. *)
        if checked then
          "Checked only; nothing ran and the session is unchanged.\n\n"
          ^ transcript
        else transcript;
      structured =
        `Assoc ([ "status", `String "ok";
                  "phrases", `List (List.map (json_phrase payload) phrases) ]
                @ (if checked then [ "checked", `Bool true ] else [])
                (* Only when it is not the default: a caller knows what it
                   passed, and a phrase that was rewritten says so itself. *)
                @ (match autorun with
                    | Msg.Ran_under names when names <> Msg.autorun_default ->
                      [ "autorun", `List (List.map (fun n -> `String n) names) ]
                    | _ -> []));
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
      (* A runtime failure has no span, and a first phrase has nothing done
         before it: absent then, like any other field with nothing to say. *)
      structured =
        `Assoc ([ "status", `String "failed";
                  "phase", `String (Msg.string_of_phase f.phase);
                  "phrase", `Int (f.phrase_index + 1);
                  "message", `String f.message ]
                @ (if f.spans = [] then [] else [ "spans", spans_json f.spans ])
                @ (if f.lines = [] then [] else [ "lines", spans_json f.lines ])
                @ (if f.done_ = [] then []
                   else [ "phrases", `List (List.map (json_phrase payload) f.done_) ]));
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
        `Assoc
          ([ ("status", `String (if failed = [] then "ok" else "partial"));
             ("loaded", `List (List.map (fun l -> `String l) loaded)) ]
           @ (match failed with
               | [] -> []
               | fs ->
                 [ ("failed",
                    `List (List.map (fun (lib, err) ->
                        `Assoc [ ("library", `String lib);
                                 ("error", `String err) ]) fs)) ]));
      is_error = false }
  (* A stop is not a completion and does not pretend to be one: the caller has
     to know the phrase is still waiting, and with which id. *)
  | Msg.Stopped { id; name; site_id; site_at; phrase_index; bound; skipped;
                  done_ } ->
    let names =
      String.concat ", "
        (List.map (fun (b : Msg.binding) ->
             Printf.sprintf "%s : %s" b.Msg.bound b.Msg.bound_type) bound) in
    let head =
      Printf.sprintf "Stopped at [%%break %S] #%d (%s)%s, id %d.%s%s"
        name site_id (at_text site_at)
        (if phrase_index >= 0 then Printf.sprintf " in phrase %d" (phrase_index + 1)
         else "")
        id
        (match bound with
         | [] -> " Nothing was in scope to bind."
         | _ -> " Bound " ^ names ^ ".")
        (match skipped with
         | [] -> ""
         | _ ->
           "\nSkipped, because the type cannot be written outside the phrase: "
           ^ String.concat "; "
               (List.map (fun (n, why) ->
                    Printf.sprintf "%s (%s)" n (String.trim why)) skipped))
    in
    let body = transcript payload done_ in
    { content = (if body = "" then head else body ^ "\n" ^ head);
      structured =
        `Assoc
          ([ ("status", `String "stopped"); ("id", `Int id);
             ("marker", `String name);
             ("site", `Assoc (("id", `Int site_id) :: at_fields site_at)) ]
           @ (match bound with
               | [] -> []
               | bs ->
                 [ ("bound",
                    `List (List.map (fun { Msg.bound; bound_type } ->
                        `Assoc [ ("name", `String bound);
                                 ("type", `String bound_type) ]) bs)) ])
           @ (match skipped with
               | [] -> []
               | ss ->
                 [ ("skipped",
                    `List (List.map (fun (n, why) ->
                        `Assoc [ ("name", `String n);
                                 ("reason", `String why) ]) ss)) ])
           @ (match done_ with
               | [] -> []
               | ps -> [ ("phrases", `List (List.map (json_phrase payload) ps)) ]));
      is_error = false }
  | Msg.Markers_listed { markers; swapped; unknown; unknown_sites } ->
    let plural n = if n = 1 then "" else "s" in
    let line (m : Msg.marker) =
      Printf.sprintf "  %-20s %-6s %s, %d hit%s%s" m.Msg.marker m.Msg.marker_kind
        (if m.Msg.armed then "armed" else "disarmed") m.Msg.hits
        (plural m.Msg.hits)
        (String.concat ""
           (List.map (fun (st : Msg.marker_site) ->
                Printf.sprintf "\n    #%-4d %s, %d hit%s  (%s)" st.Msg.id
                  (if st.Msg.site_armed then "armed" else "disarmed")
                  st.Msg.hits_here (plural st.Msg.hits_here)
                  (at_text st.Msg.where))
               m.Msg.sites))
    in
    let body = match markers, swapped with
      | [], [] -> "no markers in this session"
      | ms, [] -> String.concat "\n" (List.map line ms)
      | ms, sw ->
        String.concat "\n"
          (List.map line ms @ [ "swapped: " ^ String.concat ", " sw ])
    in
    let never = unknown @ List.map (Printf.sprintf "#%d") unknown_sites in
    let note = match never with
      | [] -> ""
      | ns ->
        Printf.sprintf "\n\nthis session has never seen: %s"
          (String.concat ", " ns)
    in
    { content = body ^ note;
      structured =
        `Assoc
          (("markers",
            `List (List.map (fun (m : Msg.marker) ->
                `Assoc ([ ("name", `String m.Msg.marker);
                          ("kind", `String m.Msg.marker_kind);
                          ("armed", `Bool m.Msg.armed);
                          ("hits", `Int m.Msg.hits) ]
                        @ (match m.Msg.sites with
                            | [] -> []
                            | ss ->
                              [ ("sites",
                                 `List (List.map (fun (st : Msg.marker_site) ->
                                     `Assoc ([ ("id", `Int st.Msg.id) ]
                                             @ at_fields st.Msg.where
                                             @ [ ("armed", `Bool st.Msg.site_armed);
                                                 ("hits", `Int st.Msg.hits_here) ]))
                                     ss)) ])))
                markers))
           :: (match swapped with
               | [] -> []
               | sw -> [ ("swapped", `List (List.map (fun n -> `String n) sw)) ])
           @ (match unknown with
               | [] -> []
               | ns -> [ ("unknown",
                          `List (List.map (fun n -> `String n) ns)) ])
           @ (match unknown_sites with
               | [] -> []
               | is -> [ ("unknown_sites", `List (List.map (fun i -> `Int i) is)) ]));
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
