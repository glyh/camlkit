---
status: open
type: research
blocked-by: [017]
assignee:
---

# Marshal instead of JSON metadata

## Question

[Serialization format for worker IPC](017-serialization-benchmark.md) chose
JSON metadata plus a raw byte segment, and surveyed `bin_prot`, `msgpck`,
`cbor` and `yojson` to get there. `Marshal` is absent from that survey, which
is a gap in the record rather than a decision: it is stdlib, so it was not in
a table of libraries, and it is the one option that adds no dependency and
still removes the hand-written codec.

Both ends already share `wire/msg.ml`, so the type is common by construction.
The question is whether that is enough to make an unsafe read safe in
practice, and whether what it buys is worth what it gives up.

## Measured

**It works across the two modes**, which is the first thing that could have
killed it. The worker is bytecode and the server native; a record marshalled
by a `byte_complete` executable was read back correctly by a native one built
from the same source. Values have one representation, so there is nothing
mode-specific in the format.

**It is faster and smaller, by a margin that does not matter.** Medians over
2000 iterations, against the same record encoded the way `Msg` encodes it now.
The captured program output is not in either column, because the raw segment
already keeps it out of both.

| Phrases | Marshal bytes | Marshal enc/dec ms | JSON bytes | JSON enc/dec ms |
| --- | --- | --- | --- | --- |
| 1 | 58 | 0.0001 / 0.0001 | 141 | 0.0004 / 0.0013 |
| 10 | 325 | 0.0005 / 0.0006 | 1018 | 0.0029 / 0.0080 |
| 100 | 3418 | 0.0060 / 0.0111 | 10202 | 0.0265 / 0.0588 |
| 1000 | 39966 | 0.0787 / 0.0649 | 106506 | 0.4577 / 0.8050 |

Five to twelve times faster, and under a third the size. At a hundred phrases,
which is already a large request, the whole saving is 68 microseconds against
a process round trip and a phrase that was actually evaluated. Speed is not
an argument here in either direction, and the ticket should not pretend it is.

**What it would delete: about 168 lines**, the hand-written encoders and
decoders from `string_of_phase` to `response_of_json` in `wire/msg.ml`. That
is the real case for it. Every variant added since has cost two functions and
a round-trip test, and that is the tax being questioned.

**What it costs: a mismatch is silent garbage, not an error.** Measured, not
argued. A reader whose record gained one field, reading a frame written by the
old one:

    extra=70183167196076 rendering=      exit 0

A pointer read as an integer and a string read as empty, exiting successfully.
A different layout segfaults instead. `Marshal.from_string` casts blind, which
is the whole difference from a decoder that can fail.

## What that means here

The two ends do share `msg.ml`, so drift needs two binaries built from
different sources. That is not hypothetical:

- `CAMLKIT_WORKER` exists precisely so a caller can point the server at
  another worker binary, per the architecture note.
- The worker is installed separately from the server, per
  [Making it installable](020-installability.md), so an interrupted or partial
  install leaves a new server beside an old worker.
- Bytecode is already version-locked to the compiler, which is a documented
  hazard, but it fails loudly today. Under Marshal, a stale worker would fail
  quietly.

Today that drift produces a decode error naming a field. Under Marshal it
produces a wrong value or a crash in the server, which is the process that
must never die.

## Open

**The mitigation is a header, and the frame has none.** `Frame` is two
length-prefixed segments with no magic and no version, so there is nowhere for
a build stamp to live. Adding one - `Sys.ocaml_version` plus a format number,
checked before the first read - reduces the hazard to type drift between two
binaries of the same compiler version, which is the same-build case. That is a
change to `Frame` rather than to `Msg`, and it is worth having regardless of
what carries the metadata.

**The dumpability that 017 bought.** That ticket accepted losing the
whole-frame dump and explicitly kept the metadata readable through a JSON
tool. Marshal gives that up too. Worth asking whether anything actually reads
it, or whether it was a comfort that has never been used.

**Whether 168 lines is the right measure of the tax.** They are mechanical and
well covered by round-trip tests, so they are cheap to keep and cheap to
extend. The cost is paid per new variant, at review time, not at runtime.

Benchmark and the mismatch demonstration were run against the real record
shape; they are not kept in the repo, unlike
[assets/serialization-bench.ml](../assets/serialization-bench.ml), because
reproducing them needs two binaries built from deliberately different source.
