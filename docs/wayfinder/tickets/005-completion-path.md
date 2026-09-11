---
status: open
type: research
blocked-by: []
assignee:
---

# How completion works over the protocol

## Question

Partly answered by the worker prototype. `UTop_complete.complete` is
called directly and returns a start offset plus a list of pairs; `List.ma`
yielded `map map2 mapi` at offset 5.

What remains: what the second element of each pair actually carries, since
it may be type information rather than a plain suffix; what input context
the caller must supply for completion inside a partial phrase; and
whether completion is a useful MCP tool on its own or only meaningful
alongside the type lookup still in fog.
