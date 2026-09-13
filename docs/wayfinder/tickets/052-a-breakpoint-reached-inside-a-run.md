---
status: resolved
type: defect
blocked-by: [035, 019]
assignee: lyh
---

# A breakpoint reached inside a run

## Symptom

[Breakpoints in a session](035-breakpoints.md) refuses a breakpoint in a phrase
that autorun will run as a promise, because stopping escapes the blocking run.
The check looks at the phrase being sent. A breakpoint defined in an earlier
call and reached from inside a later autorun phrase is not seen by it, and
stops anyway.

Measured on the installed build, with `lwt.unix` required:

    let hb () = [%break "inner"]; 7;;                     -> ok
    Lwt.map (fun () -> hb ()) (Lwt_unix.sleep 0.01);;     -> stopped, ran: lwt
    Lwt.map (fun () -> 5) (Lwt_unix.sleep 0.01);;         -> Exception: Failure
                                                             "Nested calls to
                                                             Lwt_main.run are
                                                             not allowed".
    continue                                              -> val _1 : int = 7
    Lwt.map (fun () -> 5) (Lwt_unix.sleep 0.01);;         -> val _3 : int = 5

The same after `continue` with `abandon`: the scheduler works again once the
parked phrase is released.

## What this means

The harm is narrower than 035 says. 035 gives as the reason for refusing that
"every later promise phrase in the session would fail". With Lwt that holds
only while the phrase is parked; resuming or abandoning it unwinds out of
`Lwt_main.run` and the next run starts. What a caller meets meanwhile is a
message about nested runs, which names nothing it did.

Async is not measured. It is not installed in the switch this was tested in,
and its scheduler may not recover the way Lwt's does.

## Open

- **Refuse at the stop, or explain the failure.** The hook could know it is
  inside a run - the autorun rewrite knows which phrase it wrapped - and fail
  that phrase with a sentence, as it already does for a stop in a frame the
  runtime entered. Or the stop is allowed, and a promise phrase that fails
  while a phrase is parked inside a run says so instead of relaying Lwt's
  message.
- **Whether the static refusal is still earned.** If Lwt recovers after
  release, a breakpoint written directly in an autorun phrase is no worse than
  this case. Measuring Async decides it.

## Decided

**Explain the failure; the stop stays allowed.** Each parked phrase records the
autorun rule its phrase ran under (`Breakpoint.parked.run`). A phrase that runs
under the same rule and fails at execute gets a note after the scheduler's
message, naming the parked phrase by the id `continue` takes and the marker it
stopped at:

    Exception: Failure "Nested calls to Lwt_main.run are not allowed".

    This phrase ran under autorun lwt while the phrase parked as id 1
    (stopped at "inner") is still inside its own lwt run. A run cannot start
    while another has not returned: continue or abandon it, then send
    this again.

Beside the message, not instead of it, and no matching on its text: while a
run is parked, an Lwt promise phrase can only fail this way, but a promise
phrase under Async, which is not measured, might fail for a reason of its own,
and then both are shown rather than ours hiding it.

Refusing at the stop was rejected. It would take away a working stop, because
Lwt recovers once the phrase is released, to prevent a failure that now
explains itself.

Tested in `a run blocked by a parked run says so`: the stop, the failure with
the note, no note on a phrase that is not a run, and runs working again after
`continue`.

## Still open

Whether the static refusal in 035 is still earned. It turns on Async, which is
still not measured, and nothing here changed it.
