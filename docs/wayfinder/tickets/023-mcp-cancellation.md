---
status: open
type: prototype
blocked-by: []
assignee:
---

# Honour a cancellation notification

## Question

MCP defines a cancellation notification for an in-flight request. We ignore
every notification, so a client that gives up on a slow evaluation is still
charged the full deadline, and the worker keeps running.

The machinery is already here, which is why this is a prototype rather than
a question: `Supervision` has an interrupt-then-kill escalation and the
server tracks one pending request per session. Cancelling is the same
escalation triggered by a message instead of by a clock.

Decide what the cancelled request returns, if anything, and whether the
session survives - an interrupt leaves it usable, so it should.

Noted as missing in [ocaml-mcp](https://github.com/tmattio/ocaml-mcp) too,
where it is called out as needing thread-safe cancellation tokens. Our
select loop needs no tokens: the signal goes to a different process.
