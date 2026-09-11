---
status: closed
type: grilling
blocked-by: []
assignee: lyh
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

## Resolution: shelled out, after the RPC route was tried and abandoned

The decision above was to supervise a watching dune and read diagnostics over
RPC, because RPC carries them as data. That was attempted and abandoned.
Recording what was learned, because each step looked like the last obstacle:

1. **The `dune rpc` command reports no diagnostics.** `dune rpc build` answers
   `Success` or `Failure` and nothing else, which is less than a plain build
   gives. This is a limitation of the command, not the protocol.
2. **The one published hand-rolled client does not work against dune 3.24.**
   ocaml-platform-sdk sends a one-shot `(version 1.0)`; the real sequence is
   `initialize` followed by a `version_menu` negotiation. Its last commit is
   2025-07-22.
3. **dune's client functor deadlocks under an identity monad.** `connect_raw`
   contains `let handler = Fiber.Ivar.read handler_var in`, which with
   `'a t = 'a` blocks immediately, before any thread exists to fill the ivar.
   A fiber must be a deferred computation. With `'a t = unit -> 'a` over
   threads, the handshake completes and diagnostics come back correctly - this
   was demonstrated working.
4. **The public API has no build request.** It offers ping, diagnostics,
   flush_file_watcher, format_dune_file, promote and build_dir. `dune rpc
   build` works because dune's command line declares the procedure itself, in
   `src/dune_rpc_impl/decl.ml`. That declaration can be mirrored through
   `Dune_rpc.Private`, which was done.
5. **With all of that, the build request hangs.** Client, server and watcher
   all idle at zero CPU, waiting on a response that does not arrive. Cause
   unknown.

So: `dune build`, shelled out. No watcher, no second process kind, no private
protocol, no Experimental interface. The location header is lifted into
`severity`, `file`, `line` and `col`; the compiler's own prose stays the
message, with dune's source echo and caret underline stripped because the
caller already has the file and the position is a field.

**dune has no structured output for this.** Checked: every display mode is
human text, and `dune diagnostics`, which sounds like the answer, is an RPC
client and answers "RPC server not running" without a watcher. Two flags make
the text less fragile, and are used: `--display-separate-messages` and
`--error-reporting=deterministic`.

What was removed with the RPC route: `lib/fiber.ml`, `lib/chan.ml`,
`lib/dune_client.ml`, `lib/watcher.ml`, and the `dune-rpc` and `csexp`
dependencies. The threaded fiber is the piece worth remembering: it is the
only known way to drive dune's client functor without an event loop, and it
worked.

## Amendment: dune's own words are a field

Reported from a session: a bad target returned `{"status":"failure",
"diagnostics":[]}` and nothing else, leaving nothing to act on. dune had said
`Error: Don't know how to build lib/nonexistent`, and that text was in the
result's display half but not in its structured half, which is where a caller
looks. The tool description promised it "alongside the diagnostics", so the
description was right and the field was missing.

`output` now carries everything dune said, capped like other output. It is
the whole answer whenever a failure has no located diagnostic to parse: a bad
target, a dune file error, a missing dependency.
