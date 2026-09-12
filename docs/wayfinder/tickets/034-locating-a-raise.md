---
status: resolved
type: defect
blocked-by: []
assignee: lyh
---

# A raise in a phrase had no position

## Symptom

An exception from evaluated code could not be located. A session reported

```
Failure("here")
Called from unknown location
```

where the stock toplevel, given the same phrases, reports

```
Called from <unknown> in file "//toplevel//", line 1, characters 12-20
```

So an agent whose own code raised could not tell which expression did it, even
though a type error in the same code comes back with spans.

## Cause

The worker never set `Clflags.debug`, so phrases were compiled without debug
events. `ocaml` sets it; we had inherited none of that, having built the
toplevel up from compiler-libs in
[Removing the utop dependency](022-drop-utop.md). Recording backtraces was not
the missing half: with recording on and events absent, the frame is still
unknown.

## Fixed

One line at worker init: `Clflags.debug := true`, beside the `real_paths`
setting that was already there. A raise then reports
`Called from _1 in file "//toplevel//", line 1, characters 12-20`.

**Recording is left to the caller.** `Printexc.record_backtrace` is not
forced on, because the stock toplevel does not force it either and it costs
something on every raise. A session that wants backtraces turns it on, which
now works; before this, turning it on bought nothing.

**The positions are in the caller's own frame of reference.** Characters count
into the code string that was sent, which is what
[What an eval returns to the agent](004-eval-result-contract.md) already uses
for error spans, so a backtrace and a type error now point at text the same
way.

**Cost.** Debug events make phrase bytecode larger, and the toplevel retains
the event table for each fragment it compiles, so a very long session holds
more than it did. Both were judged worth an exception that can be located; the
alternative is a flag, and a session-level switch for something a caller
cannot know to ask for is worse than paying for it.

**Interaction with instrumentation.** Debug events are generated from
locations, so anything inserted into a phrase must not move the caller's text,
see [Stopping inside a running phrase](033-breakpoints-are-an-effect.md).

Covered by "a raise can be located" in the server suite, which asks for a
backtrace through the tool surface and checks the phrase is named.
