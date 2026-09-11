---
status: open
type: prototype
blocked-by: []
assignee:
---

# utop session driver over Eio

## Question

Build the core: a session that owns a `utop -emacs` child process and
turns a phrase into a captured result.

Covers spawning under an Eio switch, reading the startup lines to learn
the phrase terminator, the line codec, sentinel framing, the per-eval
deadline, and poison detection with a clean kill. `lib/proto.ml` already
holds the pure codec with Alcotest cases; this is the effectful half.

Deliberately excludes the MCP layer. Drive it from a test or a scratch
binary. The question it answers is whether the framing holds up against
real phrases: long output, exceptions, warnings, phrases that never
terminate, and a phrase that reads stdin.
