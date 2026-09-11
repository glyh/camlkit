---
status: open
type: grilling
blocked-by: []
assignee:
---

# Building the project from a tool

## Question

The edit-build-reload loop is one call only after the build has happened
elsewhere. An agent editing a file must leave this server, run `dune build`
some other way, and come back. A build tool would close the loop.

[ocaml-mcp](https://github.com/tmattio/ocaml-mcp) exposes three:
`dune/build-status`, `dune/build-target` and `dune/run-tests`, via Dune RPC
rather than by shelling out, which gives structured diagnostics rather than
scraped text.

## Decided

**A build tool belongs here, and it supervises a watching dune per project.**

The cost is larger than the tool list suggests, and was checked before
choosing. Dune RPC does not run builds: `dune rpc build` states it requires
dune already running in passive watching mode, and `dune rpc status` against
a real project answers `RPC server not running`. The CLI also marks the whole
mechanism Experimental.

So this server starts and owns a `dune build --watch` per project. That is a
second kind of child process, with a lifetime, a failure mode and a cleanup
path of its own, alongside the session workers. Accepted deliberately: it is
the only route to structured diagnostics rather than scraped text, and it
makes rebuilds incremental rather than full.

## What remains to decide

Where a watcher's lifetime is bound. Per project or per session; what happens
when two sessions name the same project; whether it dies with the server, and
what reaps it if the server is killed rather than asked to stop.

What a build returns. Diagnostics are the point, so their shape matters more
than the summary.

How this composes with `load`. A successful build invalidates a loaded
session, which is exactly the interface mismatch `load`'s reset flag exists
for. Building and reloading in one call is the loop the whole ticket is
about, but it would also make a build implicitly destroy session state.

Their TODO notes a build needs a timeout, which the existing deadline gives,
and cancellation matters more here than anywhere else: a build is the longest
thing this will ever do. See
[Honour a cancellation notification](023-mcp-cancellation.md).
