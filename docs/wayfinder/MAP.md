# Map: MCP interface for UTOP

## Notes

**Domain.** An MCP server, written in OCaml 5, that gives an MCP client
(an agent) one or more live OCaml toplevels. It drives stock `utop` from
opam as a child process, speaking the line protocol utop already exposes
for Emacs via its `-emacs` flag. No fork of utop, no patch to it.

**Purpose.** Both an agent scratchpad REPL and a codebase exploration
tool, built eval-first. Completion and library loading follow once eval
is solid.

**Skills every session should consult.** `ocaml-alcotest` for anything
touching the test suite. `ponytail` governs scope: the laziest thing that
works, and no speculative abstraction.

**Standing preferences.** Build against opam's utop, never the reference
checkout at `/home/lyh/pullground/mina/utop`, which is behind opam.
`opam env` is not loaded in the user's fish shell, so every build command
must evaluate it first. Tests are Alcotest.

## Decisions so far

- [Architecture baseline](tickets/001-architecture-baseline.md) — subprocess
  speaking utop's `-emacs` protocol; named multiple sessions; Eio for
  concurrency and cancellation; poisoned sessions are killed, not repaired;
  output framed by a fully-qualified sentinel phrase.

## Fog

- **Project launch context.** Deferred deliberately. Whether a session can
  be started inside a dune project so its libraries are preloaded, via
  `dune utop`, or whether libraries are always pulled in on demand. Unknown
  whether `dune utop` even forwards `-emacs` cleanly.
- **Beyond completion.** Type lookup, documentation lookup, jump-to-source.
  utop's completion may or may not be the right substrate; merlin may be a
  better fit for some of it, at the cost of a second subsystem.
- **Toplevel directives.** How `#use`, `#load`, `#directory` and a user's
  `.utoprc` interact with a server-managed session. Possibly a security
  boundary, possibly a feature.
- **Resource limits.** A phrase can allocate until the machine dies. A
  deadline bounds time but nothing bounds memory.
- **History.** utop's protocol exposes history navigation and
  `save-history`. Unclear whether an agent client wants any of it.
- **Packaging.** How this gets installed and registered with an MCP client,
  and whether it is worth publishing to opam.
