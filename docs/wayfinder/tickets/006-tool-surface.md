---
status: closed
type: grilling
blocked-by: [002, 004]
assignee: lyh
---

# Session lifecycle and the tool surface

## Question

Settle the tools the server exposes and how sessions are addressed.
Whether a session is created explicitly or implicitly on first use by
name, what happens to a name whose session was killed as poisoned, whether
a session is ever reaped for idleness, and what a caller sees when it
names a session that no longer exists.

Also outstanding, found while auditing the scaffolding: only `eval`
declares an `outputSchema`. [MCP semantics to target](002-mcp-wire-contract.md)
settled that results should carry `structuredContent`, but what `describe`
and `require` return is this ticket's business, so their schemas wait on it.

Depends on the MCP result shape and on what an eval returns, so it cannot
be settled before those.

## Resolution

**Four tools: `eval`, `describe`, `require`, `reset`.** All four declare an
`outputSchema`, so every result is machine-readable rather than only eval's.

**Sessions are created implicitly on first use**, addressed by a name the
caller chooses. No create or list tool: an agent does not want to manage
lifecycle it does not care about, and every tool competes for the model's
attention.

**`reset` discards a session and starts it clean.** This exists so that
getting back to a known state does not mean inventing a new name, which
would leave the old toplevel running until the server exits. It is served
entirely server-side, with no worker round trip.

**A dead session's name stays usable, and the first result after the
restart says so.** The name is only a handle; refusing it forever would
force an agent to invent new names after every crash, and nothing would
reclaim the old ones.

This corrected a real inconsistency found while closing the ticket. The
code removed a dead session from its table, so the next call under that
name silently spawned an empty toplevel. The comment beside it claimed the
opposite, and the error told the caller to use a different name. That is
precisely the behaviour
[Protocol between server and worker](015-worker-ipc.md) rejected, arriving
one call later by accident. The note is attached once, not repeated, and a
`reset` is not reported as a restart, since the caller asked for it.
