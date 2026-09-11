---
status: closed
type: research
blocked-by: []
assignee: lyh
---

# JSON-RPC codec: library or hand-rolled

## Question

No MCP SDK exists for OCaml, so the earlier assumption was that the whole
JSON-RPC layer would be hand-written. Check whether a JSON-RPC library
exists before writing one.

## Resolution

**Use the `jsonrpc` package.** It is the JSON-RPC implementation extracted
from `ocaml-lsp`, published separately, currently 1.27.0. Its dependencies
are only dune, yojson and OCaml >= 4.08, so it carries no LSP baggage and
no competing concurrency runtime.

Critically it is a **pure message codec with no transport**. It contains no
`Content-Length` framing and reads no channels, so it does not drag in
LSP's framing, which MCP does not use. MCP over stdio is newline-delimited
JSON, and we do that read ourselves with Eio and hand each line to
`Packet.t_of_yojson`.

Verified by round-trip against MCP-shaped messages: emits `"jsonrpc":"2.0"`
on responses, errors and notifications, maps `MethodNotFound` to `-32601`,
parses a `tools/call` request, and parses an id-less
`notifications/initialized` as a notification rather than choking.

`Packet.t` covers the request, notification, response and batch cases.
`Response.Error.Code` carries some LSP-specific codes that are simply
unused, and `Other of int` covers anything MCP needs beyond the standard
set.

The residual risk is that the package is versioned and released with
ocaml-lsp, so it moves on that project's schedule. Acceptable for a codec
this small and this stable.

Rejected hand-rolling, which would have been a few hundred lines to
reimplement something already correct and maintained.
