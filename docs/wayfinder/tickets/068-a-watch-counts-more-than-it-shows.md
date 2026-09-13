---
status: resolved
type: defect
blocked-by: [049]
assignee: lyh
---

# A watch counts more than it shows

## Symptom

A watch's entry in an eval result pairs a total with a window. After a phrase
stopped at a breakpoint having recorded `1`, `2`, `3`, `continue` answered

    {"name":"step","hits":5,"values":["4","5"]}

`values` is what this phrase recorded, as ticket 049 decided, and `hits` is
every hit the site has had. Read together they say five hits produced two
values, which is also what a run of equal values stored once with a count looks
like, so the shape is ambiguous rather than merely surprising.

## Direction

Make the two agree on the window: `hits` in an eval result counts this phrase's
hits, and the lifetime total stays where it already is, in `markers` and
`inspect`.

## Resolved

As directed. A site keeps `call_hits` beside `this_call`, counted by `record`
and emptied by `start_call`, which `continue` also calls, so a resumed phrase
counts from the resume like its values do. An eval or continue result's `hits`
is that count; `inspect` and `markers` keep the lifetime total. The transcript
says `(N hits)` when the count exceeds the values shown, which repeats and the
cap both cause.
