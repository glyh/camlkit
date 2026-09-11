# camlkit

An MCP server that gives an agent live OCaml toplevels and source queries.

A worker process owns the toplevel, over the compiler's own
`compiler-libs.toplevel`; the server supervises one worker per session and
speaks MCP over stdio. State persists between calls within a session, so an
agent can build up an environment and explore it.

## Security

**This executes arbitrary OCaml with your privileges. It is not sandboxed,
and that is deliberate.**

A phrase can call `Sys.command`, open sockets, read your files or delete
them. The toplevel is driven by a model rather than by you typing.

This is a trusted local developer tool. The reasoning is recorded in
`docs/wayfinder/tickets/012-trust-boundary.md`: the server already runs with
exactly your privileges, the MCP host gates tool invocation behind your
consent, and confining the worker would break library loading and project
exploration, which is most of the point.

The assumption that makes this acceptable is that stdio implies a local
parent process that you launched. **Anyone exposing this over a non-stdio
transport, or to a client they do not control, is handing out remote code
execution.** Do not do that.

## Installing

You do not need to clone this repository.

**Install it into the same opam switch as the project you want to explore.**
The worker is bytecode, and bytecode is version-locked: a worker built with
OCaml 5.4 cannot load artifacts compiled by 5.3. If you only want to poke at
installed libraries, any switch will do.

Into your current switch:

```sh
opam pin add camlkit https://github.com/glyh/camlkit.git
```

Into a project that has its own local switch, which is the case that matters
if you want to reach that project's own code:

```sh
opam pin add --switch /path/to/project \
  camlkit https://github.com/glyh/camlkit.git
```

This installs two binaries into that switch's `bin`. `camlkit` is the
server; `camlkit-worker` is the toplevel it spawns, one per session. The
server finds the worker beside its own executable, so they must stay
installed together. `CAMLKIT_WORKER` overrides that if you need a specific
build.

Requires OCaml 5.3.0 or newer. Everything else comes in as a dependency.

### From a clone, for development

```sh
eval $(opam env)          # fish: eval (opam env)
dune build
dune test
dune install
```

To build against a different switch without disturbing your default build:

```sh
PROJ=/path/to/project
opam install --switch $PROJ jsonrpc ocamlfind yojson merlin alcotest lwt
opam exec --switch $PROJ -- dune build --build-dir=/tmp/camlkit-build
opam exec --switch $PROJ -- \
  dune install --build-dir=/tmp/camlkit-build --prefix=$PROJ/_opam
```

## Registering it with Claude Code

Run this from inside the project directory. **Use an absolute path**: the
client spawns the command with the environment it inherited, and a bare
`camlkit` only resolves when the opam bin directory is on `PATH`, which it
often is not.

```sh
cd /path/to/project

# current switch
claude mcp add camlkit "$(opam var bin)/camlkit"

# a specific switch, wherever opam actually put it
claude mcp add camlkit "$(opam var bin --switch /path/to/project)/camlkit"

claude mcp list        # expect: camlkit: ... - ✔ Connected
```

Ask opam where the binary is rather than assuming a layout: a global switch
lives under `~/.opam/<name>/bin` and a local one under `<project>/_opam/bin`,
and `opam var bin --switch` covers both.

`claude mcp add` defaults to `--scope local`, which registers the server for
that project only and keeps it private to you. Prefer that over
`--scope project`, which writes a committed `.mcp.json` recording an
absolute path specific to your machine.

For any other MCP client that reads a JSON config:

```json
{
  "mcpServers": {
    "camlkit": { "command": "/absolute/path/to/camlkit" }
  }
}
```

Nothing else needs opam at runtime. The server locates the worker by its own
path rather than through `PATH`, and findlib's configuration is compiled in,
so `require` works from a bare environment, including packages carrying C
stubs: the worker adds the switch's `stublibs` to its own search path rather
than relying on `CAML_LD_LIBRARY_PATH`. Verified with `PATH=/usr/bin:/bin`,
an empty environment and `lwt.unix`.

## Using it

Ten tools, in two groups.

A bare `Lwt` or `Async` expression is run rather than handed back as a
promise, the way utop does it. `eval` takes an `autorun` list to change that
per session: omit it to leave the setting alone, pass `[]` to keep the
promise. Every result reports the rules in force, and a phrase that was
rewritten names the rule that ran it, so neither the setting nor the rewrite
has to be inferred.

**About values, in a session.** `eval` runs OCaml phrases, `describe` shows a
signature, `require` loads findlib packages, `load` brings in a dune
project's own libraries, `reset` empties a session. A reset takes optional
`code`, evaluated in the fresh toplevel in the same call, which is how helpers
go back without a window where the session is empty. Nothing is remembered:
the next reset empties those too. Sessions are created on
first use under whatever name you pick, and state persists between calls.

**About source, with no session.** `locate` finds where a name is defined,
`type_at` gives the type at a position, `outline` lists what a file defines,
`uses` finds every occurrence, `search_type` finds values by their type.
These need nothing built and nothing loaded.

There is no build tool: build the project with `dune build` yourself, then:

```
load { path: "/path/to/project" }
```

That is the whole thing. `load` asks `dune top` for the directives the
project needs, so its own libraries and its external dependencies arrive
together, in dependency order. For a directory that is not a dune project it
falls back to scanning for archives. After rebuilding the project, pass `reset: true`:
loading a changed archive into a session holding the old one fails on an
interface mismatch. The session remembers which findlib packages it was
required to load, and restores them across that reset, so the rebuild loop
stays one call.

The worker must be built with the same OCaml version as the project, because
bytecode is version-locked. Install into the project's own switch.

## Testing it by hand

Most behaviour is reachable through the tools, so a session can exercise it
directly: evaluate something, break it, load a project, reset.

Cancellation is the exception. A model never sends it; the client does, when
a user interrupts or a client-side timeout fires. So from inside a session
the only way to see it is to start something long and then interrupt at the
client. To exercise it deliberately, drive the server directly:

```sh
python3 scripts/cancel-check.py \
  "$(opam var bin)/camlkit" "$(opam var bin)/camlkit-worker"
```

It starts an infinite loop, cancels it, and checks two things: that no reply
arrives for the cancelled request, and that the session still evaluates
afterwards. The second matters because cancelling interrupts rather than
kills, so it should cost the phrase and not the session.

The same shape works for anything else the tool surface does not reach:
newline-delimited JSON-RPC on stdin, one JSON object per line.

## Notes on the build

The worker is bytecode, because the toplevel it links loads bytecode
archives and so has to be one itself; the server is native.

Verified on OCaml 5.3.0 and 5.4.0.

A one-line check without a client, which works from the build tree too:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"eval","arguments":{"session":"a","code":"1 + 41;;"}}}' | camlkit
```

## Status

Working end to end. All ten tools are served over MCP stdio, against
real toplevels, one worker per session. 62 tests, of which 30 drive the
server binary the way a client does.

Sessions are created on first use under whatever name the caller picks. If
a session dies, the name stays usable and the first result afterwards says
the toplevel is fresh.

## Design

`docs/wayfinder/MAP.md` is the index. Each decision has a ticket recording
what was chosen, what was rejected and why, and what was measured rather
than assumed. Superseded decisions keep their reasoning instead of being
deleted.

Layout follows functional core, imperative shell:

| Path | What it is |
| --- | --- |
| `wire/` | shared by both processes: frame codec, message types |
| `worker/` | owns the toplevel: capture, two-pass evaluation, printers, loading, request loop |
| `lib/` | session supervision, tool declarations, rendering, merlin queries |
| `bin/` | the server's select loop |

## Behaviour worth knowing

**Evaluation is all or nothing.** A request may contain several phrases.
Nothing executes unless every phrase parses and typechecks, so a failure
never leaves partial state behind.

**Directives are not accepted by `eval`.** `#require` and friends are not
typeable, so allowing them would break that guarantee. Loading a library and
showing a signature are separate tools.

**A phrase that allocates without bound is stopped.** The worker raises when
its heap passes 2048 MiB, which leaves the session usable with its bindings,
rather than letting the allocator kill the worker and lose it.
`CAMLKIT_HEAP_LIMIT_MIB` changes the ceiling.

**A runaway phrase is interrupted before it is killed.** An interrupt leaves
the toplevel usable with its bindings intact; only an unanswered interrupt
escalates to a kill, which loses the session.

**Sessions are hermetic.** No init file is evaluated, neither
`~/.ocamlinit` nor utop's, so results do not vary between machines. Printers
a library declares with `[@@ocaml.toplevel_printer]` are still installed; the
cost is only the `#install_printer` calls you would have written in such a
file by hand.
