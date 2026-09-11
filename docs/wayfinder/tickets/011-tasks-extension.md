---
status: open
type: research
blocked-by: [006]
assignee:
---

# Long evals as MCP tasks

## Question

The Tasks extension is a conceptually near-perfect fit for evaluation. A
server returns a durable `taskId` instead of blocking, the client polls
`tasks/get` through `working` to `completed`, and `tasks/cancel` is
*cooperative* — which is precisely the SIGINT-then-grace escalation
already settled. It also sidesteps the transport timeouts that make
blocking impractical beyond a few seconds, which is a real risk for any
eval that compiles a large library.

**Deferred because no client implements it.** The published extension
support matrix lists only MCP Apps, OAuth Client Credentials and
Enterprise-Managed Authorization. Tasks appears nowhere, and the spec is
explicit that a server must never return a task to a client that did not
declare support. Building it now would be building for nobody.

Revisit when a client the project actually targets declares
`io.modelcontextprotocol/tasks`. At that point decide whether tasks
replace the blocking deadline or sit alongside it, chosen per call by
expected duration.

Source: https://modelcontextprotocol.io/extensions/client-matrix
