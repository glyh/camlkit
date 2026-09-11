# utop-mcp

An MCP server that gives an agent live OCaml toplevels.

A worker process links the `utop` library and owns the toplevel; the server
supervises one worker per session and speaks MCP over stdio. State persists
between calls within a session, so an agent can build up an environment and
explore it.

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
opam pin add utop-mcp https://github.com/glyh/utop-mcp.git
```

Into a project that has its own local switch, which is the case that matters
if you want to reach that project's own code:

```sh
opam pin add --switch /path/to/project \
  utop-mcp https://github.com/glyh/utop-mcp.git
```

This installs two binaries into that switch's `bin`. `utop-mcp` is the
server; `utop-mcp-worker` is the toplevel it spawns, one per session. The
server finds the worker beside its own executable, so they must stay
installed together. `UTOP_MCP_WORKER` overrides that if you need a specific
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
opam install --switch $PROJ utop yojson jsonrpc alcotest
opam exec --switch $PROJ -- dune build --build-dir=/tmp/utop-mcp-build
opam exec --switch $PROJ -- \
  dune install --build-dir=/tmp/utop-mcp-build --prefix=$PROJ/_opam
```

## Registering it with Claude Code

Run this from inside the project directory. **Use an absolute path**: the
client spawns the command with the environment it inherited, and a bare
`utop-mcp` only resolves when the opam bin directory is on `PATH`, which it
often is not.

```sh
cd /path/to/project

# current switch
claude mcp add utop "$(opam var bin)/utop-mcp"

# a specific switch, wherever opam actually put it
claude mcp add utop "$(opam var bin --switch /path/to/project)/utop-mcp"

claude mcp list        # expect: utop: ... - ✔ Connected
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
    "utop": { "command": "/absolute/path/to/utop-mcp" }
  }
}
```

Nothing else needs opam at runtime. The server locates the worker by its own
path rather than through `PATH`, and findlib's configuration is compiled in,
so `require` works from a bare environment. Verified with `PATH=/usr/bin:/bin`
and no opam variables set.

## Using it

Five tools. `eval` runs OCaml phrases in a named session, `describe` shows a
signature, `require` loads findlib packages, `load` brings in a dune
project's own libraries, and `reset` empties a session. Sessions are created
on first use under whatever name you pick, and state persists between calls.

To explore the project you are working in, build it, then:

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
  "$(opam var bin)/utop-mcp" "$(opam var bin)/utop-mcp-worker"
```

It starts an infinite loop, cancels it, and checks two things: that no reply
arrives for the cancelled request, and that the session still evaluates
afterwards. The second matters because cancelling interrupts rather than
kills, so it should cost the phrase and not the session.

The same shape works for anything else the tool surface does not reach:
newline-delimited JSON-RPC on stdin, one JSON object per line.

## Notes on the build

The worker is bytecode, because utop ships no native archive; the server is
native.

Verified on OCaml 5.3.0 and 5.4.0.

A one-line check without a client, which works from the build tree too:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"eval","arguments":{"session":"a","code":"1 + 41;;"}}}' | utop-mcp
```

## Status

Working end to end. `eval`, `describe`, `require` and `reset` are served
over MCP stdio against real toplevels, one worker per session. 37 tests, of
which 13 drive the server binary the way a client does.

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
| `worker/` | owns the toplevel: capture, two-pass evaluation, request loop |
| `lib/` | session supervision, tool declarations, MCP dispatch |
| `bin/` | the server's select loop |

## Behaviour worth knowing

**Evaluation is all or nothing.** A request may contain several phrases.
Nothing executes unless every phrase parses and typechecks, so a failure
never leaves partial state behind.

**Directives are not accepted by `eval`.** `#require` and friends are not
typeable, so allowing them would break that guarantee. Loading a library and
showing a signature are separate tools.

**A runaway phrase is interrupted before it is killed.** An interrupt leaves
the toplevel usable with its bindings intact; only an unanswered interrupt
escalates to a kill, which loses the session.

**Sessions are hermetic.** Your `~/.config/utop/init.ml` is not loaded, so
results do not vary between machines. The cost is that toplevel printers
installed there are absent, and your own types print as `<abstr>`.
