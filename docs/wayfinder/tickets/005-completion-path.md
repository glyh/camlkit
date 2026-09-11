---
status: open
type: research
blocked-by: []
assignee:
---

# How completion works over the protocol

## Question

Probed directly in the worker prototype. `UTop_complete.complete
~phrase_terminator ~input` returns a start offset and a list of pairs.

**The second element is not type information.** It is an insertion
suffix: `#requ` completes to `require` with suffix `" \""`, and ordinary
identifiers carry an empty one. So candidates are **names only**.

It is context-aware mid-expression: `let z = x + 1 in Strin` returns
`String` and `StringLabels` at offset 17. Directives complete. But `x.`
where `x : int` returned 132 module names rather than anything
type-directed, so it falls back rather than using the type of the prefix.

**The open question is now whether completion is the right shape at all.**
It is designed for a human typing character by character. An agent does
not type; it asks what exists in a module and what shape those things
have. Names without types may be the wrong answer to the question an
agent is actually asking, and we are in-process with the live toplevel
environment, so richer answers are available.
