---
status: open
type: prototype
blocked-by: [015]
assignee:
---

# Session driver over Eio

## Question

Build the core: a session that owns a worker child process and turns a
phrase into a captured result.

Covers spawning under an Eio switch, the per-eval deadline, the interrupt
escalation, and reaping a dead worker. The framing problems that
dominated this ticket are gone now that the worker owns its own output
channel; see
[Worker linked to utop replaces the subprocess protocol](014-worker-architecture.md).

Deliberately excludes the MCP layer. Drive it from a test or a scratch
binary. The question it answers is whether supervision holds up against real
phrases: long output, exceptions, warnings, and phrases that never
terminate.
