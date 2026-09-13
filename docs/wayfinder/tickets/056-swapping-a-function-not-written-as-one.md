---
status: open
type: research
blocked-by: [054]
assignee:
---

# Swapping a function not written as one

## Gap

The load rewrite in
[Swapping a function in a loaded project](054-swapping-a-function-in-a-loaded-project.md)
only covers a binding whose expression is syntactically a function
(`let f x = ...`, `fun`, `function`). These are left as built, and `[%swap]`
refuses them:

    let f = memoize slow          (* a function computed by an expression *)
    let pp = Fmt.list pp_item     (* partial application *)
    external f : int -> int = "c_stub"
    let rate = 0.20               (* a value *)

The rewrite is untyped, so for the first two it does not know the arity or the
labels, and wrapping with a guessed arity could change evaluation order or an
optional argument's erasure. A value is read once by callers at their module's
initialisation, so no cell on it can reach them.

## Direction

For computed functions, a typed pass could learn the arity from the `.cmt`, or
the cell could hold the whole value and callers read it through a stub that
takes exactly the arguments the type says. Measure what share of a real
project's top-level functions fall outside the syntactic rule before building
either; if it is small, the refusal message is the answer.
