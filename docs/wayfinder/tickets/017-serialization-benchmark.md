---
status: open
type: research
blocked-by: []
assignee: lyh
---

# Serialization format for worker IPC

## Question

Framing is length-prefixed. Which serialization library carries the
payload?

The payload shape drives this. Requests are small: a session id, a request
kind, and a source string of tens to hundreds of bytes. Responses are
dominated by a single large string, the captured toplevel output, ranging
from a hundred bytes to megabytes, plus small metadata: a status, optional
error spans as integer pairs, an optional warning string. Message rate is
low, but latency on a large payload matters.

The hypothesis to test is that for one big opaque string plus a handful of
tiny fields, the format barely matters, because cost is dominated by
copying the string. The only structural difference is that JSON must
escape it while binary formats write it raw behind a length prefix. If
that holds, the decision is dependency weight and maintenance rather than
speed.

Candidates: `bin_prot`, `msgpck`, `cbor`, with `yojson` as the baseline we
would otherwise have used. For each, check opam availability, last
release, whether it needs a ppx, and whether it drags in a heavy
dependency tree.

Benchmark in progress.
