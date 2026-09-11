---
status: closed
type: prototype
blocked-by: [006]
assignee: lyh
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

## Resolution

Answered by what was built, rather than decided separately.

It wraps neither `UTop.require` nor the `#require` directive: both swallow
findlib errors into printed text, so a missing package reported as success.
It calls `Topfind.load` over `Findlib.package_deep_ancestors` directly and
catches `Fl_package_base.No_such_package` itself. utop is gone entirely now,
see [Removing the utop dependency](022-drop-utop.md).

Several packages in one call, yes: the tool takes an array. Success returns
the names loaded and failure returns `{library, error}` per package, the same
shape as `load`, rather than an empty result whose meaning had to be inferred
from the absence of an error.

Largely superseded in practice by
[Loading a dune project's own libraries](021-dune-aware-load.md): `dune top`
reports a project's external dependencies along with its own libraries, so
requiring them separately is no longer the normal path.
