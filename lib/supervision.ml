(* Functional core for session supervision. No processes, no descriptors, no
   clock: time arrives as an argument. The escalation is the part most worth
   testing and the part hardest to test if it is entangled with signalling,
   so it lives here as a transition function and the shell performs whatever
   it returns. *)

type state =
  | Idle
  | Busy of { deadline : float; signalled : bool }
  | Dead of string

type event =
  | Sent of { now : float; timeout : float }
  | Replied
  | Expired of { now : float; grace : float }
  | Vanished of string

(* What the shell should do, having applied the transition. *)
type action =
  | Nothing
  | Interrupt        (* SIGINT: leaves the toplevel usable and bindings intact *)
  | Reap of string   (* SIGKILL and wait; the session is gone *)

let step state event =
  match state, event with
  | Dead _, _ -> state, Nothing
  | _, Vanished why -> Dead why, Reap why
  | Idle, Sent { now; timeout } ->
    Busy { deadline = now +. timeout; signalled = false }, Nothing
  | Busy _, Sent _ -> state, Nothing          (* refused before reaching here *)
  | Busy _, Replied -> Idle, Nothing
  | Idle, Replied -> Idle, Nothing
  (* First expiry interrupts and grants a grace period. A SIGINT is recoverable,
     so killing outright would discard state that is still usable. *)
  | Busy { signalled = false; _ }, Expired { now; grace } ->
    Busy { deadline = now +. grace; signalled = true }, Interrupt
  (* Second expiry means the interrupt went unanswered, which is what a phrase
     that swallows Sys.Break looks like. Nothing short of a kill ends it. *)
  | Busy { signalled = true; _ }, Expired _ ->
    let why = "did not respond to interrupt before the grace period expired" in
    Dead why, Reap why
  | Idle, Expired _ -> Idle, Nothing

(* A toplevel is strictly sequential, so a second evaluation is refused rather
   than queued: a queued call would spend its deadline waiting, which the
   caller cannot distinguish from a hang. *)
let may_send = function
  | Idle -> Ok ()
  | Busy _ -> Error "session is busy with another evaluation"
  | Dead why -> Error ("session is dead: " ^ why)

let deadline = function Busy { deadline; _ } -> Some deadline | Idle | Dead _ -> None
let is_busy = function Busy _ -> true | Idle | Dead _ -> false
