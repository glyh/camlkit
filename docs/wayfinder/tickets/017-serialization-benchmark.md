---
status: closed
type: research
blocked-by: []
assignee: lyh
---

# Serialization format for worker IPC

## Question

Framing is length-prefixed. Which serialization library carries the
payload? The response is dominated by one large string, the captured
toplevel output, from a hundred bytes to megabytes, plus small metadata.

## Resolution

**Add no serialization dependency. Split the frame into two segments:**

```
[4 bytes: length of A][A: JSON metadata][4 bytes: length of B][B: raw output bytes]
```

The metadata is small and structured, so JSON costs nothing there. The
output is written and read as raw bytes and never enters JSON, so it is
never escaped. The reader takes a length, copies that many bytes, and
never inspects them. The length prefixes are what make that possible: any
delimiter-scanning scheme has to look at every byte, which is exactly the
cost being avoided.

The tradeoff accepted is that a frame is no longer one self-describing
object, so it cannot be dumped through a JSON tool whole. The metadata
still can, and it holds everything except program output, which is plain
text regardless.

## Benchmark

Medians, OCaml 5.4.0, 300 iterations (40 at 1 MB and above). Record was a
session id, status variant, the output string, an `(int * int) list
option` and a `string option`. Baseline is a hand-rolled `Buffer` with a
4-byte length prefix, which is what the chosen design actually does.

| Payload | Library | Encode ms | Decode ms |
| --- | --- | --- | --- |
| 100 KB | baseline | 0.005 | 0.002 |
| 100 KB | bin_prot | 0.005 | 0.005 |
| 100 KB | msgpck | 0.005 | 0.002 |
| 100 KB | yojson | 0.185 | 0.279 |
| 10 MB | baseline | 0.754 | 0.313 |
| 10 MB | bin_prot | 0.756 | 0.790 |
| 10 MB | msgpck | 0.749 | 0.313 |
| 10 MB | yojson | 17.949 | 27.259 |

**The hypothesis half held.** Among binary formats it held exactly:
bin_prot, msgpck and cbor all sit within noise of raw `Buffer` copying at
every size, so speed is no reason to choose between them. It failed for
JSON, where escaping costs 24x encode and 87x decode against baseline at
10 MB, plus 6% size. That is the one structural difference, and it is
larger than "barely matters".

Because the binary formats buy nothing over raw copying, and the JSON cost
is entirely the escaping of one field, removing that field from JSON
captures the whole win at zero dependency cost.

## Library survey

| Library | opam | Last upstream | Dependencies |
| --- | --- | --- | --- |
| yojson | 3.0.0 | active | none |
| bin_prot | v0.17.0-1 | active | 17 packages: base, ppxlib, 8 ppx |
| msgpck | 1.7 | dormant since 2021 | ocplib-endian |
| cbor | 0.5 | dormant since 2022 | ocplib-endian |
| ocaml-msgpack | absent | n/a | n/a |

Rejected `bin_prot`: 17 packages and a ppx for one record type, and it
ties the wire format to a Jane Street version window. Rejected `msgpck`
and `cbor`: both dependency-light and ppx-free, but dormant, and they buy
speed the two-segment frame already provides for free.

Benchmark source kept at
[assets/serialization-bench.ml](../assets/serialization-bench.ml); it
includes a round-trip assertion for all five paths.
