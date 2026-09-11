---
status: open
type: research
blocked-by: []
assignee:
---

# MCP wire contract to target

## Question

There is no MCP SDK for OCaml in opam, so the JSON-RPC layer is
hand-written. Pin exactly what has to be implemented before writing it:
which protocol revision to target, the `initialize` handshake and its
capability negotiation, the `notifications/initialized` follow-up, the
shape of `tools/list` and `tools/call`, how a tool reports failure as
opposed to a transport error, and which parts of the spec a server may
legitimately omit.

Produce a markdown summary as a linked asset, concrete enough to
implement from without returning to the spec.
