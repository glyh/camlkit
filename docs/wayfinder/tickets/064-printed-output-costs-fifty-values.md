---
status: open
type: research
blocked-by: [004]
assignee:
---

# Printed output costs fifty values

## Symptom

Two caps on one result, set independently. A phrase's printed output is clamped
at `Msg.output_limit`, 16 KiB. A value the toplevel prints is cut by its own
printer: `String.make 100_000 'x'` rendered about 300 characters and
`(* string length 100000; truncated *)`.

Measured on the installed build: `for i = 1 to 200_000 do print_string
"abcdefgh" done` returned 16 KiB of output and
`[output truncated, 1583616 more characters]`, several thousand tokens of
context for a loop that printed the same eight bytes. A value's rendering never
costs more than a few hundred.

## Open

Whether 16 KiB is the right ceiling for a caller that is a model. The count in
the marker (ticket 004) already says how much was lost, so a smaller clamp loses
no information a caller could act on, and one wanting the rest reruns with the
output going somewhere it can read. Measure what real phrases print before
choosing a number; keeping the head and the tail rather than only the head is
the other half of the question, since the end of a log is usually where the
failure is.
