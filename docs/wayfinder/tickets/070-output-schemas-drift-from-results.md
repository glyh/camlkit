---
status: open
type: defect
blocked-by: [002, 062]
assignee:
---

# Output schemas drift from results

## Symptom

Found while fixing [063](063-failures-that-read-as-answers.md). `locate`
declared an output of `file`, `line` and `col`, while every result it has ever
sent carries `location`: the schema described fields that never appear. That
one is corrected. The rest were compared by hand against the keys
`lib/render.ml` and `bin/main.ml` emit, September 2026:

- `eval` declares `phrases`, `autorun` and `checked`. Its results also carry
  `status` (`ok`, `failed`, `rejected`, `interrupted`, `stopped`, `error`),
  `phase`, `message`, `reason`, `id`, `name`, `note` after a restart, and
  since 063 `exit_code` or `signal`. A client reading the schema learns nothing
  of how an eval fails.
- `markers` returns `unknown_sites` and does not declare it.
- Every tool can answer `Render.infrastructure_failure`, whose `status` and
  `message` appear in no schema but those that list `status`.

Nothing is invalid as sent: `outputSchema` sets no `additionalProperties`, so
extra keys conform. The cost is a schema that is wrong by omission, and one
that was wrong outright with no test to notice.

## Direction

A test is the fix that stays fixed: for each result the server suite already
produces, every top-level key of `structuredContent` is declared in that tool's
`outputSchema`. Then declare what it finds missing. Whether a shared failure
shape belongs in every schema is the surface question 063 left open, and may
be worth settling first.
