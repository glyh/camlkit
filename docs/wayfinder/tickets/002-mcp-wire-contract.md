---
status: closed
type: research
blocked-by: []
assignee: lyh
---

# MCP semantics to target

## Question

The JSON-RPC codec is a solved dependency, so what remains is the MCP
layer on top of it: which revision to target, the handshake, the shape of
`tools/list` and `tools/call`, and how a tool reports failure as opposed
to a transport error.

## Resolution

Read against the published spec. **Two assumptions in the original
question were already obsolete.**

**The current revision is 2026-07-28, and the `initialize` handshake is
retired.** That exchange, `notifications/initialized`, and the
`Mcp-Session-Id` header are gone. A client may optionally call
`server/discover` to learn capabilities, but no handshake is required and
any request can land on any server instance.

**Agree on the client's protocol version, do not impose ours.** Found by
registering with a real client: Claude Code sends
`protocolVersion: "2025-11-25"` and refuses to connect to a server that
answers `initialize` with anything else, reporting
`Server's protocol version is not supported`. Tool dispatch is identical
across these revisions, so `initialize` echoes back whatever the client
asked for and only `server/discover` advertises our own newest.

Nothing caught this, because every test sent `initialize` with no
`protocolVersion` at all. The first real client found it immediately.

**Speak both handshakes.** Answer `initialize` if a client sends it,
answer `server/discover` if it sends that, and dispatch tools identically
either way. The divergence is confined to a couple of methods at the edge,
so supporting both is cheap and avoids betting on migration speed.

**The stateless core explicitly blesses the named-session design.** The
spec notes that dropping the protocol-level session does not force the
application to be stateless, and that a server needing state across calls
should "mint an explicit handle from a tool and have the model pass it
back as an argument". That is exactly a session id as a tool parameter, so
the session model settled in the architecture baseline is the documented
pattern rather than a workaround.

**`isError` is reserved for infrastructure failure.** A phrase that fails
to typecheck, or raises at runtime, is a successful eval whose verdict is
negative, and comes back as ordinary content. `isError` is set only when
the server failed at its own job: the session is dead, the spawn failed,
or the deadline forced a kill. The agent then reads diagnostics as
information rather than as the call having broken, and the two cases
demand completely different responses.

**Declare an `outputSchema` and return `structuredContent`.** The utop
protocol already hands us separated streams: the `accept:` verdict with
error spans, warnings and errors on `stderr:`, values on `stdout:`, and
new bindings. Flattening that into one text blob discards structure the
agent would have to regex back out of prose. Human-readable text content
ships alongside for display.

**Result mechanics.** `tools/call` returns a `content` array that is
always present, `structuredContent` when the tool declared an
`outputSchema`, and `isError` when the tool ran and failed. Arguments
failing the input schema come back as an `isError` result without the
handler running.

**The Tasks extension is deferred**, tracked separately. See
[Long evals as MCP tasks](tickets/011-tasks-extension.md).

## Sources

- https://modelcontextprotocol.io/specification/
- https://blog.modelcontextprotocol.io/posts/2026-07-28/
- https://modelcontextprotocol.io/extensions/tasks/overview
- https://modelcontextprotocol.io/extensions/client-matrix
