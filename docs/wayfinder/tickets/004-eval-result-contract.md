---
status: closed
type: grilling
blocked-by: [002, 003]
assignee: lyh
---

# What an eval returns to the agent

## Question

utop reports parse verdict and error spans on `accept:`, but sends
warnings, type errors and runtime exception traces all on `stderr:`,
while values land on `stdout:`. An agent consuming this needs to tell a
compile error from a warning from a runtime failure, because the next
action differs in each case.

Two parts of this are already settled by
[MCP semantics to target](002-mcp-wire-contract.md): a failed phrase is an
ordinary result, never an `isError`, and the tool declares an
`outputSchema` so results carry `structuredContent`.

What remains is the field-level detail. What the schema's fields actually
are, how warnings are separated from errors given that utop sends both on
`stderr:`, how the error spans on `accept:` map back onto the submitted
source, and how the `_N` implicit bindings are surfaced.

Needs real captures from the session driver to decide against, not
guesses, and cannot be settled before the MCP result shape is pinned,
since whatever is decided here has to be expressed in it.

## Resolution

Implemented as `lib/render.ml`, a pure function from a worker response plus
the raw output segment to an MCP tool result, so it is testable without a
toplevel.

**Fields.** Each phrase carries its `rendering` (the toplevel's own output),
its `warnings`, its `output` (sliced from the raw segment), and whether that
output was `truncated`. A failure carries the phase, the 1-based phrase
number, the message, byte `spans` and line ranges.

**Warnings are separated from rendering** by pointing
`Location.formatter_for_warnings` at its own buffer.

**Error locations are structured, and the message arrives without its
location prefix**, since `get_ocaml_error_message` strips it. The
human-readable half puts the line back so it reads like a compiler message.

**`isError` stays false for any phrase-level failure**, including a
rejected directive, and is true only for the server failing at its own job:
an unknown tool, a missing argument, a session that is busy or dead, or a
worker that could not be started. Verified end to end.

**The text half reads as a transcript** in terminal order: warnings, then
what the phrase printed, then what the toplevel made of it.

## Amendment: the rendering was the biggest violation of the structural rule

`rendering` packs a binding name, a type and a value into one string, so
asking what type a phrase produced meant parsing `val _0 : int = 42`. The
type is the thing a caller most often wants.

Each phrase now carries an `outcome` alongside the rendering:

- `{kind: value, type, value}` for a bare expression
- `{kind: bindings, items: [{name, type, value?}]}` for a `let`, `type`,
  `module` and so on
- `{kind: exception, exception}` and `{kind: nothing}`

`Toploop.print_out_phrase` is a ref holding a printer over
`Outcometree.out_phrase`, which still has the pieces separate. We wrap it
rather than replace it, because utop installs its own from a module
initializer and its text is what we display. The `Outcometree` constructors
we destructure are identical on 5.3 and 5.4, checked in both switches. The
printers are `Format_doc` printers, bridged with `Format_doc.compat`, which
exists on both.

`require` was the other violation: it returned an empty phrase result, so
success had to be inferred from the absence of an error. It now reports the
packages it loaded, reusing the same shape as `load`.

Left as prose deliberately: `describe`, whose payload is OCaml signature
text, where structuring would mean reimplementing the printer; and a
failure `message`, which is a compiler diagnostic already accompanied by
structured `phase`, `spans` and `lines`. `warnings` remains a single string
and is the one soft spot left.
