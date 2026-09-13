---
status: resolved
type: defect
blocked-by: [002, 062, 071]
assignee: lyh
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

Superseded by [Tools declared from their types](071-tools-declared-from-their-types.md):
results and arguments derived from types, so drift is a compile error rather
than something a test samples. What follows was the first proposal.

A test is the fix that stays fixed: for each result the server suite already
produces, every top-level key of `structuredContent` is declared in that tool's
`outputSchema`. Then declare what it finds missing. Whether a shared failure
shape belongs in every schema is the surface question 063 left open, and may
be worth settling first.

## Resolved

By building [Tools declared from their types](071-tools-declared-from-their-types.md).
Every tool's arguments and result are types with `[@@deriving mcp]`, and
`Tool.make` or `Tool.deferred` builds the declaration from them; there is no
hand-written schema left, and `lib/tools.ml` is gone. The fields this ticket
found undeclared are now declared because they are constructors of the result
type: `eval`'s `status`, `phase`, `message`, `reason`, `note`, `id`, and the
failure's `exit_code` and `signal`, and `markers`' `unknown_sites`. The input
side had drifted too, and in the other direction: `load` read a `packages`
argument its schema never listed. The typed `load` does not read it.
