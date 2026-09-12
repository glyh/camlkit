---
status: resolved
type: defect
blocked-by: []
assignee: lyh
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

## Measured

Markers written to the capture file at each stage boundary, flushed, put both
remaining copies inside the two typecheck passes rather than the execute pass:

    <<PASS1>> [warning] <<PASS2>> [warning] <<EXEC>>

Then the deciding test. Replacing the capture buffer with a formatter that
discards everything left both copies in place, and the wrapper reported
capturing nothing:

    <<PASS1>><<CAPTURED 0 bytes>> [warning] <<PASS2>><<CAPTURED 0 bytes>> [warning]

So each typing prints the warning twice: once through
`Location.formatter_for_warnings`, which the wrapper catches, and once through
something that does not read that ref at all. Nothing in this project prints
it, so the second printer is inside the compiler. The execute pass does not do
this - its single copy goes through the ref into the phrase's warnings.

The guess this ticket recorded, that three copies meant three typings and the
duplication was a symptom of the passes, was wrong. There are three typings,
but that is not why.

## The fix

Not the second printer, which is not ours and need not be found. The capture
file is where a phrase's *program output* is read from, and nothing in it
before execution begins can be program output: a phrase cannot print before it
runs. So the capture is reset between the last typecheck pass and the first
execution, and everything the compiler said while typing is dropped with it.

One line, at the point where the passes end. It also covers whatever else the
compiler may print during typing, which chasing this one printer would not
have.

A warning now arrives once, in the phrase's `warnings`, where it started out
arriving five times.

Covered by "a warning arrives once" in the worker suite, which counts the
copies in the warnings and in the payload, and then checks that a phrase's own
output still reaches it and is still addressed to the right phrase with a
warning raised between two printing phrases.
