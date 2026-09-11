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

```sh
eval $(opam env)
dune build
dune install          # or: opam install .
```

This installs two binaries. `utop-mcp` is the server; `utop-mcp-worker` is
the toplevel it spawns, one per session. The server finds the worker beside
its own executable, so they must stay installed together. Override with
`UTOP_MCP_WORKER` if you need to point at a specific build.

## Using it

It speaks MCP over stdio, so point any MCP client at the `utop-mcp`
command. For a client that reads a JSON config:

```json
{
  "mcpServers": {
    "utop": { "command": "utop-mcp" }
  }
}
```

For Claude Code: `claude mcp add utop utop-mcp`.

**Give the absolute path if your shell does not have `opam env` loaded.**
The client spawns the command with the environment it inherited, so a bare
`utop-mcp` only resolves when the opam bin directory is on `PATH`:

```sh
claude mcp add utop "$(opam var bin)/utop-mcp"
```

Nothing else needs opam at runtime. The server locates the worker beside
its own executable rather than through `PATH`, and findlib's configuration
is compiled in, so `require` works from a bare environment. Verified with
`PATH=/usr/bin:/bin` and no opam variables set.

Four tools become available. `eval` runs OCaml phrases in a named session,
`describe` shows a signature, `require` loads findlib packages, and `reset`
empties a session. Sessions are created on first use under whatever name
the caller picks.

## Building

`opam env` must be in scope:

```sh
eval $(opam env)
dune build
dune test
```

Requires OCaml 5.3.0 or newer and `utop`. The worker is bytecode, because
utop ships no native archive; the server is native.

Verified on OCaml 5.3.0 with utop 2.17.0 and on 5.4.0 with utop 2.16.0, so
it is not pinned to either.

A one-line check without a client, which works from the build tree too:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"eval","arguments":{"session":"a","code":"1 + 41;;"}}}' | utop-mcp
```

## Status

Working end to end. `eval`, `describe`, `require` and `reset` are served
over MCP stdio against real toplevels, one worker per session. 30 tests,
including nine that drive the server binary as a client would.

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
