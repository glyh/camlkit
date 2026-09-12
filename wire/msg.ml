(* Request and response types crossing the server/worker boundary.
   Metadata rides in the first segment, marshalled; captured program output is
   the raw segment, addressed by per-phrase offsets. *)

type request =
  (* [autorun] names the rewrites this session performs, if the caller wants
     to change them. Absent leaves the session as it was. *)
  | Eval of { source : string; autorun : string list option }
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
  (* [autorun] is the session's rule list as it now stands, echoed on every
     eval so a caller can see what the setting is without probing for it. None
     for the answers that are not an eval. *)
  | Completed of { phrases : phrase list; autorun : string list option }
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
  | Stopped of { id : int; phrase_index : int;
                 bound : binding list;
                 skipped : (string * string) list;
                 done_ : phrase list }
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
