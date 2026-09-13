---
status: open
type: defect
blocked-by: [049]
assignee:
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
