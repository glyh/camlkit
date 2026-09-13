---
status: resolved
type: defect
blocked-by: [027, 053]
assignee: lyh
---

# outline answers bottom up

## Symptom

`outline` of `lib/supervision.ml` on the installed build listed `is_busy`
(line 53) first and `state` (line 7) last, and each type's constructors in
reverse too: `Reap`, `Interrupt`, `Nothing` for a type declared
`Nothing | Interrupt | Reap`. That is merlin's order passed through.

A caller reading an outline to decide what to read next reads a file upside
down, and one that takes the first match of a repeated name gets the last
definition, which in OCaml is the one that shadows - right by accident only.

## Direction

Sort items and children by `start` in the trim ticket 053 added, which already
walks every level.

## Resolved

Not in the trim: `trim` is shared with `type_at`, whose enclosings are
innermost first, and `search_type`, whose results are ranked, both on purpose.
`Merlin.in_source_order` sorts outline items and each item's `children` by
`start`, stably, and only `outline` calls it.
