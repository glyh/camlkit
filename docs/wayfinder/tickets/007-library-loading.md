---
status: open
type: prototype
blocked-by: [006]
assignee:
---

# Loading libraries into a session

## Question

Settled in outline: loading is its own tool, because `eval` rejects
directives outright. See
[Protocol between server and worker](015-worker-ipc.md).

What remains is the tool's own behaviour. Whether it wraps `UTop.require`
or evaluates a `#require` directive internally, what a load failure looks
like given findlib raises `Fl_package_base.No_such_package`, whether
loading several packages in one call is worth it, and what the tool
returns on success, since loading a package prints to stdout and may emit
deprecation alerts like the auto-include one seen during prototyping.

This is the codebase exploration half of the purpose, so it matters beyond
convenience.
