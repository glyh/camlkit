---
status: open
type: research
blocked-by: []
assignee:
---

# MCP semantics to target

## Question

The JSON-RPC codec is a solved dependency, so what remains is the MCP
layer that sits on top of it.

Pin which protocol revision to target, the `initialize` handshake and its
capability negotiation, the `notifications/initialized` follow-up, the
exact shape of `tools/list` and of a `tools/call` result, how a tool
reports a failure as opposed to a transport error, and which parts of the
spec a server may legitimately omit.

Produce a markdown summary as a linked asset, concrete enough to
implement from without returning to the spec.
