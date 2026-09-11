---
status: closed
type: grilling
blocked-by: []
assignee: lyh
---

# Trust boundary

## Question

The server evaluates arbitrary OCaml with the user's privileges, driven
by a model rather than by someone typing. A phrase can call `Sys.command`,
open sockets or delete files. The MCP specification calls tools "arbitrary
code execution" that hosts must gate, and requires explicit user consent
before invoking any tool.

## Resolution

**This is a trusted local developer tool and is not sandboxed.** The
decision is explicit rather than an omission, and belongs in the README so
nobody deploys it somewhere it does not belong.

The reasoning: the server already runs with exactly the privileges of the
user who launched it, the MCP host gates tool invocation behind user
consent, and confining the child would defeat the stated purpose. Loading
the user's own libraries, exploring their own project and running
`dune utop` against it all require reaching the filesystem the sandbox
would remove.

Rejected confining the child with landlock or bubblewrap. It would break
library loading, dune integration and project exploration, which is most
of the point, for a threat model that does not apply to a process the user
started themselves against their own code.

The consequence to write down: anyone exposing this over a non-stdio
transport, or to a client they do not control, is handing out remote code
execution. stdio implies a local parent the user launched, and that
assumption is load-bearing.
