---
status: open
type: defect
blocked-by: []
assignee:
---

# A warning arrives several times over

## Symptom

One warning in one phrase reached the caller five times. Measured through the
tool surface on `let f l = match l with [] -> 0;;`, before
[Typecheck without running](041-typecheck-without-running.md) touched
anything: `Warning 8 [partial-match]` appeared once in the phrase's `warnings`
field and four more times inside its `output` field.

That is a result landing in a model's context carrying the same forty words
five times, which is the opposite of what
[What an eval returns to the agent](004-eval-result-contract.md) decided about
what a result should cost.

## Cause, the half that is understood

`Capture` redirects the worker's stdout and stderr onto the capture file, and
that file is what `output` is read from. `Location.formatter_for_warnings` is
a global, set to a per-phrase buffer only inside the execute pass. During the
two typecheck passes it was therefore still pointing at `Format.err_formatter`,
so every warning those passes raised was written to stderr and collected as if
the phrase had printed it.

Capturing the typecheck passes, which 041 did for its own reasons, removes two
of the four. A warning now arrives three times: once in `warnings`, twice in
`output`.

## Not understood

Where the remaining two come from. The execute pass sets
`Location.formatter_for_warnings` to the phrase's warning buffer before
`Toploop.execute_phrase`, and exactly one copy does arrive there. Two more
reach stderr during the same call, from something that is not honouring the
formatter or is reporting through another route. Not chased, because 041 had
no need to.

## Worth knowing before fixing

The fix is probably not another formatter swap. Three copies of a warning per
phrase means the phrase is being typed three times, and if that is so then the
duplication is a symptom of the passes rather than of where they print. The
thing to measure first is how many times a phrase is typed on the way to
running, not how many times a warning is printed.
