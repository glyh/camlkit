---
status: open
type: defect
blocked-by: [027, 004]
assignee:
---

# merlin fields with nothing to say

## Symptom

The merlin-backed tools forward merlin's answer under a named key, and merlin's
answer carries fields that restate a default or an empty list. That breaks the
convention in [What an eval returns to the agent](004-eval-result-contract.md):
a field with nothing to say is absent, not present and empty.

Seen on the installed build:

- `outline`: every item carries `"children": []` and `"deprecated": false`, and
  a `selection` span beside `start`/`end`.
- `uses`: every occurrence carries `"stale": false`.
- `type_at`: every enclosing carries `"tail": "no"`.

An outline of `worker/watch.ml` repeats these on each of its items, which is
where the cost is: a large file's outline pays for them once per definition.

Not a regression from the recent work. `bin/main.ml` passed merlin's value
through the same way at b3b5a41.

## Open

- **Drop or keep `selection`.** It is the name's own span inside the item's, so
  it is not a restatement; it may be what a caller wants for `locate` or
  `uses` on the name. Measure whether anything reads it before removing it.
- **Where the trimming lives.** `Merlin.diagnostics` already strips `valid`,
  `type` and empty `sub` from diagnostics. The same shape of function per tool
  in `lib/merlin.ml` keeps the pass-through in `bin/main.ml` unchanged.
