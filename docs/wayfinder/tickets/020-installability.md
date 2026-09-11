---
status: closed
type: task
blocked-by: []
assignee: lyh
---

# Making it installable

## Question

Everything passed in the build tree. Did any of it work once installed?

## Resolution

**No. `opam install utop-mcp` produced a server that could not start a
single session.** Only the server had a `public_name`, so only it reached
`bin`. The worker was built but never installed, and the server looks for
`utop-mcp-worker` beside its own executable, which would never exist.

No ticket covered this, because every test ran against paths inside
`_build`, and the integration tests set `UTOP_MCP_WORKER` explicitly. The
one path a user takes was the one path nothing exercised.

Fixed by giving the worker `(public_name utop-mcp-worker)`. Verified by
installing to a scratch prefix and driving the installed server over MCP
from an unrelated working directory with no environment override:
evaluation and state persistence both worked.

The coupling is deliberate but fragile: `worker/dune`'s `public_name` must
match the basename in `Session.worker_path`. Both carry a comment pointing
at the other.

README now covers installing, the client configuration, and the four tools.
