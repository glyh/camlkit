(* What a session tool answers, typed, and the one mapping from a worker's
   response into it. isError is not here: a phrase that fails to typecheck is
   a successful call with a negative verdict, and the server failing at its own
   job is Tool.failure. See docs/wayfinder/tickets/002, 004 and 071.

   ponytail: one result type for all eight session tools, so describe's schema
   admits a stop it can never produce. Each branch still says exactly which
   fields go with its status; split per tool if a client ever relies on the
   narrower set. *)

open Wire

type cost = {
  wall_ms : float;
  allocated_bytes : int;
} [@@deriving mcp]

type watched = {
  name : string;
  id : int;
  in_ : string option;
  (** The top-level definition holding the watch. *)
  line : int;
  code : string;
  hits : int;
  (** Hits in this phrase, the window its values come from. *)
  values : string list;
} [@@deriving mcp]

type phrase = {
  rendering : string;
  warnings : string;
  output : string;
  (** What the phrase printed, ending with how much was cut when it did not
      fit. *)
  ran : string option;
  (** The autorun rule that ran this phrase's promise. *)
  watched : watched list;
  cost : cost option;
} [@@deriving mcp]

type phase = Parse | Typecheck | Execute [@@deriving mcp]

type site = {
  id : int;
  in_ : string option;
  line : int;
  code : string;
} [@@deriving mcp]

type binding = {
  name : string;
  type_ : string;
} [@@deriving mcp]

type skipped = {
  name : string;
  reason : string;
} [@@deriving mcp]

type failed_library = {
  library : string;
  error : string;
} [@@deriving mcp]

type marker_site = {
  id : int;
  in_ : string option;
  line : int;
  code : string;
  armed : bool; [@keep_empty]
  hits : int;
} [@@deriving mcp]

type marker = {
  name : string;
  kind : string;
  armed : bool; [@keep_empty]
  (** Sent when false too, since a disarmed marker is the news. *)
  hits : int;
  sites : marker_site list;
} [@@deriving mcp]

(* [note] on every branch: the first result after a session restarted, or a
   reset the call carried, says so. *)
type t =
  | Completed of {
      phrases : phrase list;
      checked : bool;
      (** Nothing ran: the call only typechecked. *)
      autorun : string list option;
      (** The rules in force, when they were not the default; [] runs none. *)
      note : string;
    } [@name "ok"]
  | Failed of {
      phase : phase;
      phrase : int;
      (** 1-based; 0 when the whole source failed to parse. *)
      message : string;
      spans : int list list;
      (** Byte ranges into the submitted source. *)
      lines : int list list;
      phrases : phrase list;
      (** Phrases that ran before a runtime failure. *)
      note : string;
    }
  | Interrupted of { phrase : int; phrases : phrase list; note : string }
  | Stopped of {
      id : int;
      marker : string;
      site : site;
      bound : binding list;
      skipped : skipped list;
      phrases : phrase list;
      note : string;
    }
  | Loaded of { loaded : string list; note : string }
  | Partial of { loaded : string list; failed : failed_library list; note : string }
  | Markers of {
      markers : marker list;
      swapped : string list;
      unknown : string list;
      unknown_sites : int list;
      note : string;
    }
  | Unknown of { error : string; note : string }
  | Rejected of { reason : string; note : string }
  | Reset of { note : string }
[@@deriving mcp ~tag:"status"]

(* Spans are clamped by the worker before sending, so this cannot read past
   the payload; it stays defensive because a mismatch would be silent. *)
let slice payload (p : Msg.phrase) =
  let n = String.length payload in
  if p.out_len <= 0 || p.out_start < 0 || p.out_start > n then ""
  else String.sub payload p.out_start (min p.out_len (n - p.out_start))

let phrase payload (p : Msg.phrase) =
  let output = slice payload p in
  (* Truncation folds into the output it qualifies, as a count of what was
     lost, rather than a flag beside it. *)
  let output =
    if p.dropped > 0 then
      Printf.sprintf "%s\n[output truncated, %d more character%s]" output p.dropped
        (if p.dropped = 1 then "" else "s")
    else output
  in
  { rendering = p.rendering; warnings = p.warnings; output; ran = p.ran;
    watched =
      List.map
        (fun (w : Msg.watched) ->
           { name = w.site; id = w.site_id; in_ = w.at.in_def; line = w.at.line;
             code = w.at.code; hits = w.site_hits; values = w.values })
        p.watched;
    cost =
      Option.map
        (fun (c : Msg.cost) ->
           (* Three decimals is more than one un-repeated run can support. *)
           { wall_ms = Float.round (c.wall_ms *. 1000.) /. 1000.;
             allocated_bytes = c.allocated_bytes })
        p.cost }

let pairs = List.map (fun (a, b) -> [ a; b ])

let of_response ?(note = "") (response : Msg.response) payload =
  let phrases = List.map (phrase payload) in
  match response with
  | Msg.Completed { phrases = ps; autorun; checked } ->
    Completed
      { phrases = phrases ps; checked; note;
        (* Only when not the default: a caller knows what it passed. *)
        autorun = (match autorun with
            | Msg.Ran_under names when names <> Msg.autorun_default -> Some names
            | _ -> None) }
  | Msg.Failed f ->
    Failed
      { phase = (match f.phase with
            | Msg.Parse -> Parse | Msg.Typecheck -> Typecheck | Msg.Execute -> Execute);
        phrase = f.phrase_index + 1; message = f.message;
        spans = pairs f.spans; lines = pairs f.lines; phrases = phrases f.done_; note }
  | Msg.Interrupted { phrase_index; done_ } ->
    Interrupted { phrase = phrase_index + 1; phrases = phrases done_; note }
  | Msg.Loaded { loaded; failed = [] } -> Loaded { loaded; note }
  | Msg.Loaded { loaded; failed } ->
    Partial { loaded; note;
              failed = List.map (fun (library, error) -> { library; error }) failed }
  | Msg.Stopped { id; name; site_id; site_at; phrase_index = _; bound; skipped; done_ } ->
    Stopped
      { id; marker = name; note;
        site = { id = site_id; in_ = site_at.in_def; line = site_at.line;
                 code = site_at.code };
        bound = List.map (fun (b : Msg.binding) ->
            { name = b.bound; type_ = b.bound_type }) bound;
        skipped = List.map (fun (name, reason) -> { name; reason }) skipped;
        phrases = phrases done_ }
  | Msg.Markers_listed { markers; swapped; unknown; unknown_sites } ->
    Markers
      { swapped; unknown; unknown_sites; note;
        markers =
          List.map
            (fun (m : Msg.marker) ->
               { name = m.marker; kind = m.marker_kind; armed = m.armed; hits = m.hits;
                 sites =
                   List.map
                     (fun (st : Msg.marker_site) ->
                        { id = st.id; in_ = st.where.in_def; line = st.where.line;
                          code = st.where.code; armed = st.site_armed;
                          hits = st.hits_here })
                     m.sites })
            markers }
  | Msg.Unknown error -> Unknown { error; note }
  | Msg.Rejected reason -> Rejected { reason; note }
