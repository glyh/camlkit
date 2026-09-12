(* Request and response types crossing the server/worker boundary.
   Metadata rides in the first segment, marshalled; captured program output is
   the raw segment, addressed by per-phrase offsets. *)

(* What a call asks of the autorun rewrites. Saying nothing is not the same
   as saying none: [] turns the rewrites off, and the default is a rule list
   of its own, so the two need separate forms. *)
type autorun = Default_rules | Rules of string list

type request =
  (* [check] stops after the typecheck pass: the phrases are typed against the
     session's real environment and nothing runs. The rewrites still happen, so
     what is typed is what would have run. *)
  (* [cost] asks for each phrase's wall clock and allocation. Opt-in rather
     than reported when notable: most phrases cost nothing worth a number, and
     a caller that is not measuring should not pay for two of them per line. *)
  | Eval of { source : string; autorun : autorun; check : bool; cost : bool }
  | Describe of string      (* a module path, answered via #show *)
  | Require of string list  (* findlib packages *)
  (* A dune build tree, whose private libraries findlib cannot see. *)
  (* Resume or abandon a phrase parked at a breakpoint. [id] is absent when
     the session holds exactly one, which is the ordinary case. *)
  | Continue of { id : int option; abandon : bool }
  (* Bind a parked stop's locals again and print them. Separate from continue
     because looking is not resuming, and a later stop's bindings overwrite an
     earlier one's. *)
  | Inspect of { id : int option }
  (* List every marker the session knows, and arm or disarm by name. A marker
     cannot be removed - it is compiled into the code holding it - so disarming
     is what "destroy" means here. See docs/wayfinder/tickets/049. *)
  | Markers of { disarm : string list; arm : string list }
  | Load of { path : string; libraries : string list;
              (* findlib packages to load first. A reset empties the session,
                 including anything it had required, and a project's libraries
                 usually need some of those to load at all. *)
              packages : string list }

(* One record per phrase. [rendering] is the toplevel's own output, such as
   "val x : int = 42"; program output lives in the raw segment at
   [out_start, out_start + out_len). These are different questions and the
   first worker prototype wrongly concatenated them. *)
(* A name and its type, as data. Used where there is no transcript to read it
   out of: the locals a breakpoint binds. A phrase's own bindings are not
   carried this way, because its rendering already says "val f : int -> int =
   <fun>" and structure that restates readable text is not worth its bytes. *)
type binding = {
  bound : string;       (* the name, or "" for a bare expression *)
  bound_type : string;  (* its type, or the whole declaration for a type or module *)
}

(* What running a phrase cost, when the call asked. Wall clock is the half that
   invites a wrong conclusion - a first call pays for lazy initialisation, a
   toplevel is not a release build, and nothing is repeated - so the tool says
   so and the honest half is the allocation, which is a count rather than a
   timing and barely moves between runs. *)
type cost = {
  wall_ms : float;
  allocated_bytes : int;
}

type phrase = {
  rendering : string;
  warnings : string;
  out_start : int;
  out_len : int;
  (* How much of what this phrase printed did not fit the cap, in bytes. Zero
     when all of it did. A count rather than a flag, so a caller knows whether
     it lost a line or a megabyte. *)
  dropped : int;
  (* The autorun rule that rewrote this phrase, if one did. Without it the
     rewrite is invisible: a run promise and a plain value render the same way,
     and only the type hints that anything happened. *)
  ran : string option;
  (* Absent unless the call asked to be told. *)
  cost : cost option;
}

(* One marker, as the markers tool reports it. [hits] is the site's lifetime
   count, not this call's: "this has fired 4000 times" is what a caller wants
   before reading any values. *)
type marker = {
  marker : string;
  marker_kind : string;          (* "break" or "watch" *)
  armed : bool;
  hits : int;
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

(* Which rules an answer ran under, echoed on every eval so a caller can see
   what was in force without probing for it. Require and load also answer
   Completed, and have no rules to report. *)
type autorun_used = Not_an_eval | Ran_under of string list

type response =
  (* [checked] is a call that stopped after typechecking. Carried rather than
     left to the caller's memory of what it asked: a checked rendering is a run
     rendering with the value missing, and "val f : int -> int" against
     "val f : int -> int = <fun>" is too quiet a difference to rest on. *)
  | Completed of { phrases : phrase list; autorun : autorun_used;
                   checked : bool }
  (* Loading is not a phrase result and should not pretend to be one: a caller
     wants the library names as data, not a sentence to parse. *)
  | Loaded of { loaded : string list; failed : (string * string) list }
  | Failed of failure
  | Interrupted of { phrase_index : int; done_ : phrase list }
  (* A phrase performed [%break] and is parked. Mirrors Interrupted: the
     phrases that finished first are kept, since they really ran. [bound] and
     [skipped] are what became of the locals in scope at the stop; a local
     whose type cannot be written down outside the phrase is skipped with the
     compiler's own reason rather than silently missing. *)
  | Stopped of { id : int;
                 (* The marker's name. The id says which hit; this says which
                    marker, which is what a caller disarms by. *)
                 name : string;
                 phrase_index : int;
                 bound : binding list;
                 skipped : (string * string) list;
                 done_ : phrase list }
  | Markers_listed of { markers : marker list;
                        (* Names asked for that the session has never seen. A
                           typo in a disarm is otherwise silent. *)
                        unknown : string list }
  | Rejected of string       (* e.g. a directive sent to eval *)
let string_of_phase = function
  | Parse -> "parse" | Typecheck -> "typecheck" | Execute -> "execute"

(* A phrase can print without bound, and an MCP result is a single payload with
   no streaming, so captured output is capped. The limit is small because the
   result lands in a model's context: 16K of text is already about four
   thousand tokens, and a half-megabyte result overflows a tool-result limit
   and spills to a file, which helps nobody.
   Clamping is pure so it can be tested without running a toplevel.
   ponytail: one fixed limit; make it per-request if anyone needs more. *)
let output_limit = 16 * 1024

(* The rules a call runs under unless it says otherwise. Here rather than in
   the worker so the server can leave them out of a result that used them. *)
let autorun_default = [ "lwt"; "async" ]

let clamp ~limit phrases =
  let any = ref false in
  let clamp_one p =
    if p.out_len <= 0 then p                       (* nothing to cut *)
    else if p.out_start >= limit then (any := true;
      { p with out_start = limit; out_len = 0; dropped = p.out_len })
    else if p.out_start + p.out_len > limit then (any := true;
      let kept = limit - p.out_start in
      { p with out_len = kept; dropped = p.out_len - kept })
    else p
  in
  let clamped = List.map clamp_one phrases in
  (clamped, !any)
(* The wire codec is Marshal, see docs/wayfinder/tickets/043. Both ends are
   built from this file, so the types agree by construction, and Frame's stamp
   is what refuses a peer that was not. Bump Frame.format_version when the
   types above change shape.

   Nothing here is a closure, an exception or a lazy value, which are what
   Marshal cannot carry. Keep it that way: the compiler will not stop you. *)
let encode_request (r : request) = Marshal.to_string r []
let decode_request (s : string) : request = Marshal.from_string s 0
let encode_response (r : response) = Marshal.to_string r []
let decode_response (s : string) : response = Marshal.from_string s 0
