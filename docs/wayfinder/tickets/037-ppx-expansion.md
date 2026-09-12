---
status: resolved
type: research
blocked-by: [027]
assignee: lyh
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

## Decided

**A position, like every other merlin-backed tool here.** By name was
considered and declined: merlin's command takes a position and nothing else, so
answering by name means finding the deriver's column from a type's name first,
which is machinery for a caller that can get the position from `outline`. The
description says where the position has to point, because the failure sentinel
is the only other way to find out.

**The expanded code goes in the text half as source.** The generic renderer
pretty-prints JSON, which would escape every newline in generated code and make
the one thing the caller asked for unreadable. So `expand` has its own branch,
as `document` does, with the deriver's span alongside as data.

**The code as it comes, un-trimmed.** The open question was whether the bodies
are worth their bytes. They are the answer when the question is what a `let%`
does, and a caller that wants names alone has `describe` on a built module,
which the description now says.

**Not `isError` when there is no ppx there.** That is an answer about the file,
like a name with no documentation on it.

## Verified

Against `ppx_deriving.show`, which is the case the question is about: nothing in
`[@@deriving show]` tells a reader it produces `pp_point` and `show_point`.
`ppx_deriving` and `ppxlib` are test-only dependencies; neither the server nor
the worker links either, and the tool needs no ppx of its own - it asks merlin
about whichever ppx the file in front of it is configured with.

Getting there passed through a rewriter written over compiler-libs alone, which
is no longer in the tree. It was abandoned for a real one, and what it taught is
worth keeping. dune's `(preprocess (pps ...))` refuses a plain `Ast_mapper`
rewriter outright - "No ppx driver were found. It seems that demo_ppx is not
compatible with Dune" - because it wants a ppxlib-style driver.

And dune is not the route anyway. A file that gets its ppx from dune makes
merlin ask dune for the configuration, and dune will not run inside dune, which
is the wall `load` is behind. What works is that merlin still reads a `.merlin`,
so `FLG -ppx "<driver> --as-ppx"` names a ppxlib driver through the compiler's
own preprocessing protocol. Quoted, because `--as-ppx` has to be the driver's
first argument rather than a flag to the compiler; unquoted it is passed on to
the compiler and the driver reports "too many input files".

**Size, measured.** `[@@deriving show]` on a two-field record expands to 1174
bytes over 25 lines. That is the answer for the un-trimmed decision above: a few
hundred tokens for a question nothing else can answer. A large variant will be
larger, and a caller who only wants the names has `describe`.

## Open

**The structure-extension gap.** Measured once, against `ppx_expect`:
`let%test_module` and `let%expect_test` returned the sentinel at every column
tried, where an expression extension expanded. `ppx_deriving` has no structure
extension to check it against, so this is still one ppx's behaviour rather than
a rule, and the tool description promises nothing about `let%`.

**The whole-file alternative.** `dune describe pp FILE` prints the entire
preprocessed source. It builds the file first and returns everything, so it is
strictly worse for this question, but it is the only route if per-position
expansion turns out to miss the node kinds that matter.
