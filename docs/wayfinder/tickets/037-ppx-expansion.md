---
status: open
type: research
blocked-by: [027]
assignee:
---

# What a ppx generated

## Question

Macroexpansion is core to both clients surveyed: SLY has five `slynk-expand`
variants and CIDER a whole macroexpansion mode. OCaml's ppx is the same layer
and nothing on this surface shows it. An agent therefore guesses at generated
names, and guesses wrong in the way that reads as confident - whether
`[@@deriving yojson]` gives `to_yojson` or `yojson_of_t` is not derivable from
the source in front of it.

Partly covered after a build: `describe` on the built module lists the
generated names. The point is answering before one, and answering with the
code rather than with a signature.

## Measured

`ocamlmerlin single expand-ppx -position L:C` does it, on the shell-out
[Merlin-backed source queries](027-merlin-source-queries.md) already owns.
Run against `lib/ast.ml` in a project using `[@@deriving sexp]`, position on
the deriver:

    {"class":"return","value":{
       "code": "include struct ... let placeholder_of_sexp = ... end",
       "deriver": {"start":{"line":4,"col":2},"end":{"line":4,"col":19}}}}

That is the answer the agent could not otherwise get, in one call, in 105ms.

**Failure is a bare string, not an object.** At a position with no ppx the
class is still `return` and the value is
`"No PPX deriver/extension node found on this position"`. So the decoder
branches on whether the value is a string, the same shape of sentinel that
[Reading a name's documentation](032-documentation-lookup.md) had to decode.

**Expression extensions expand, structure ones do not.** `[%expect {| ... |}]`
at 26:6 expanded to its `Ppx_expect_test_block.run_test` call. `let%test_module`
and `let%expect_test` returned the sentinel at every column tried, including
the `%` itself. Worth confirming against a second ppx before believing the
rule, but a tool description should not promise `let%`.

## Open

**Whether a position is the right way to ask.** Every other merlin-backed
tool here takes one, so consistency says yes. But an agent reading a type
definition wants "what did `[@@deriving sexp]` give me on this type", and it
knows the type's name more reliably than the deriver's column. `document`
already faced this and answers both ways.

**Whether the expanded code is worth its bytes.** A deriver on a large variant
generates a lot, and the useful part is usually the names and their types
rather than the bodies. Against that: the bodies are the answer when the
question is what a `let%` actually does. Perhaps the generated code as it
comes, and the caller can ask `describe` for names alone.

**The whole-file alternative.** `dune describe pp FILE` prints the entire
preprocessed source. It builds the file first and returns everything, so it is
strictly worse for this question, but it is the only route if per-position
expansion turns out to miss the node kinds that matter.
