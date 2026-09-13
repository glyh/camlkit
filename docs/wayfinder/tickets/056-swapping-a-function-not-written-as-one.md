---
status: resolved
type: research
blocked-by: [054]
assignee: lyh
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

## Measured

The typed trees in `.cmt` files, after ppx expansion, so the code the rewrite
sees. Every top-level binding outside functors, `_`-prefixed names left out:

| | fun (5.3.0) | mina (4.14.2) |
|---|---|---|
| functions written as functions | 1,179 | 7,813 |
| functions computed by an expression | 17 | 562 |
| … aliases, `let f = M.g` | 17 | 322 |
| … partial applications | 0 | 195 |
| … other (`let ... in`, local open, `match`) | 0 | 45 |
| externals | 0 | 410 |
| values | 81 | 3,864 |

Small in both, and mostly aliases. Mina cannot be loaded at all, being 4.14,
so its column is evidence about style only. 216 of its bindings had a type that
would not expand and were counted as values.

## Decided

**Type the unit and wrap what the type says is a function.** Built anyway,
because the check is cheap to make exact. The ppx context the compiler hands
over carries the load path and the `-open` flags, so the ppx can type a unit
exactly as the compiler will. A top-level binding the syntax cannot decide
(not `let rec`, not a literal, constructor, record, tuple or array) is looked
up by its pattern's position in the typed tree, and if its type expands to an
arrow it becomes

    let f = let o = <expr> in fun ~l:p -> if held then cell ~l:p else o ~l:p

with `~l` the first parameter's label from the type.

- **`<expr>` still runs once,** at initialisation, as a value would.
- **Only the first parameter is taken.** Taking the full arity would move work
  a staged function does between its parameters. What `o p` returns is passed
  on as it was, so a partial application behaves as built. A replacement is
  checked against the whole type by the eval half as before, and called with
  the one argument.
- **Generalisation is unchanged.** A let of a non-expansive expression around a
  function is non-expansive, and an expansive one was weak before too.

**Typed only when needed, and verified.** A unit with no undecided binding is
not typed at all. A unit that got a wrapper is typed again after the rewrite,
and if that fails its wrappers are all dropped. The unit then builds with the
syntactic rewrite alone, so a case not foreseen here costs that unit's computed
swaps and never the load's build.

**Cost:** a cold `load` of `fun`, eleven libraries, went from 2.4-2.5s to
3.0-3.2s. The worker is bytecode and types each unit that needs it once or
twice. A warm load reuses dune's build and pays nothing.

**Found on the way:** `fun` never loaded at all. `let f x : t = function ...`
had its constraint moved onto the match the cases became, which was fixed
separately (0e52158).

Externals and values stay out of reach, as they were: a value is read once by
callers at their own initialisation, and an external has no OCaml body to
check a cell in. A caller that captured a partial application at its own
initialisation (`let g = M.f x`) holds what `f` returned then and does not see
a later swap, for the same reason.

Tested in the swap suite: a partial application swapped under a caller in its
own module, one with a labelled first parameter, a `Printf` partial application
behaving as built. On `fun`, all 17 aliases in `Nbe` got cells, and
`[%swap Nbe.make_cont ...]` swaps and restores.
