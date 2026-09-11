---
status: open
type: grilling
blocked-by: [002, 004]
assignee:
---

# Session lifecycle and the tool surface

## Question

Settle the tools the server exposes and how sessions are addressed.
Whether a session is created explicitly or implicitly on first use by
name, what happens to a name whose session was killed as poisoned, whether
a session is ever reaped for idleness, and what a caller sees when it
names a session that no longer exists.

Depends on the MCP result shape and on what an eval returns, so it cannot
be settled before those.
