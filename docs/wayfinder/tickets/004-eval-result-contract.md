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

## Amendment: the outcome carried the value twice

Measured after the fact: the outcome was consistently two to four times the
size of the rendering it accompanied, and almost all of the excess was its
`value` field, which duplicated the rendering exactly. A forty-element list
appeared in full in both.

The split was in the wrong place. A name and a type are data; a value is a
*printed representation* chosen by the printer, and often `<fun>`, `<abstr>`
or an elided list. So `value` is gone from the outcome and lives only in the
rendering, where the printer put it. That list case went from 232 bytes to 67.

Each item now carries its kind instead - value, type, module, modtype, class,
extension. For a type or module declaration the "type" is the declaration,
which is also what the rendering shows, so the kind is what makes the
structured form worth having there: it says what sort of thing was bound
without parsing the text.

## Amendment: the decomposition is removed

Structuring the rendering was tried for two rounds and is now gone. What
settled it was measuring which kinds the outcome could actually report:

| phrase | kind |
| --- | --- |
| `1 + 41;;` | bindings |
| `let x = 1;;` | bindings |
| `type t = A;;` | bindings |
| `let () = print_string "p";;` | nothing |
| `failwith "boom";;` | no phrase at all |

Only `bindings` and `nothing` ever occur. `value` is unreachable because
implicit bindings turn every bare expression into a binding, and `exception`
is unreachable because a raise becomes `status: failed` with the phrase
excluded from the list. So a kind hint says exactly "is the rendering
empty", which the rendering already says.

That left names and types, and those are what a utop transcript is: a
consumer that reads OCaml reads `val f : int -> int -> int = <fun>` without
help. The decomposition also cost two to four times the rendering's size
before the value was dropped from it, and even after, added bytes to every
declaration for a `kind` that restated the first word of the type.

Removed: 184 lines, including `worker/outcome.ml` and its
`Toploop.print_out_phrase` wrapper.

This is not a retreat from the standing preference that an endpoint serves
structure. That rule's own test is whether a caller could act without
reading the prose, and the fields where the answer was no all remain
structural: `phase`, `spans`, `lines`, which phrases ran before a failure,
`truncated`, and the `loaded`/`failed` arrays. What is gone is structure that
restated readable text.

## Amendment: names and types come back

Removing the whole decomposition went too far. The reasoning held for two of
its four parts and was extended to the other two without evidence.

What was genuinely degenerate stays gone. The `kind` could only ever report
`bindings` or `nothing`, which is just whether the rendering is empty, and the
`value` duplicated the rendering exactly - a forty-element list appeared twice
in full.

What came back is `bindings`: one entry per name bound, with its name and its
type, a module's type being its signature. Reported from a session using this
on a real project: reading a type otherwise means parsing the printed line
again, which is the one thing the transcript does make you do. The cost is
small and inverts for anything substantial - 27 bytes against a rendering of
18 for a simple binding, about 40 against 179 for a forty-element list.

The general lesson, worth more than the field: "this restates readable text"
was true of the value and false of the type, and both were dropped on one
argument.

## Revised: a result says only what it has to

**A field that says nothing is left out.** An empty rendering, no output, no
warnings and no bindings are absent rather than present and empty, as the
autorun rule name already was. A result is read by a model, so an empty string
is paid for in tokens and buys nothing. Measured on a one-binding evaluation:
190 bytes of structure became 110.

**Truncation is folded into the output it qualifies, and counted.** There is no
`truncated` flag. Output that did not fit ends with
`[output truncated, N more characters]`, where N comes from the clamp, which
knows exactly how much each phrase lost. A flag said something was missing; a
count says whether a line or a megabyte was missing, for the same bytes.

**The autorun rules are reported only when they were not the default.** A
caller knows what it passed, and a phrase that was rewritten credits its rule
in its own field, so echoing the default on every result was restating the
documentation.

**Nothing was folded that a caller would have to parse back out.** Bindings
stay a list of name and type, spans stay numbers, a failure still names its
phase and phrase. The rule is that structure earns its bytes by being
actionable, not by being present.

**And the bindings went the same way.** The phrase record carried each name
with its type beside a rendering that already said "val x : int = 42", so a
caller was charged twice for one fact. `worker/outcome.ml` existed only to
collect them, and its own header recorded that a kind field and a value field
had already been removed for duplicating the rendering; the remaining half
went for the same reason, and the module with it.

The measurement, for a phrase binding an integer: 190 bytes of structure at
the start of this, 110 after the empty fields went, 66 after the bindings did.
A module definition, where the entry repeated the whole signature, fell
furthest.

What this costs: a caller wanting a phrase's type as a field must read it out
of the transcript, which is one line rather than a parser. The principle that
a caller should not have to regex a message still holds where there is no
transcript to read: a breakpoint's locals keep their names and types as
fields, because a stop prints nothing.
