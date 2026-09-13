---
status: closed
type: prototype
blocked-by: [021, 049]
assignee: lyh
---

# Swapping a function in a loaded project

## Question

Clojure's `alter-var-root` and a Common Lisp redefinition change a function
under every caller that already exists. Redefining a name in an OCaml toplevel
does not: `let f x = x + 100` after `let g x = f x * 10` leaves `g` calling the
old `f`, because a toplevel phrase resolves a global when it is compiled
([Breakpoints in a session](035-breakpoints.md) relies on exactly that). Can a
session swap a function in the project it loaded, so that its callers see the
replacement? Swapping Stdlib and opam packages is explicitly not wanted.

## Measured

**Overwriting a module's field reaches half the callers.** A two-module
library, `A` with `f` and `g` calling `f`, and `B` with `h` calling `A.f`,
loaded into a bytecode toplevel, with `A.f`'s field overwritten through `Obj`:
`A.f 1` and `B.h 1` saw the replacement, `A.g 1` did not. Bytecode reads a
cross-module reference out of the module block at each use, but links a
reference inside the unit directly, and no compiler flag changes that. A call
inside its own module is the common case, and overwriting it would give a
silent wrong answer: `preview` reporting the new rate while `receipt` charged
the old one.

**An indirection on entry costs 1-2 ns per call.** Bytecode, a function
reading a `ref` and calling through it against a direct call: 50M calls of
`x + 1` took 0.43-0.47s against 0.40s; 5M calls folding a 20-element list
took 1.387s against 1.369s. That is 10-18% on a function doing nothing and
about 1% on one doing work.

**OCAMLPARAM reaches every compilation dune runs.** `OCAMLPARAM=_,ppx=<cmd>`
under `dune top --build-dir` ran the ppx on a library whose flags omit
`:standard`, and on the output of a project's own `pps ppx_deriving.show`.

## Resolution

**Rewrite at load, all functions, no fast path.** load builds the project in
`_build/camlkit` with the worker itself as a ppx (`camlkit-worker --swap-ppx`),
and every top-level function written with parameters becomes

```ocaml
let f ?x:p1 p2 =
  if Obj.is_block !cell then (Obj.obj !cell) ?x:p1 p2
  else match (match p1 with Some d -> d | None -> default) with x ->
       match p2 with pattern -> body
```

The body stays in place, so the function's type is inferred exactly as before,
polymorphism and locally abstract types included; the call through the cell
has no type of its own and adopts the parameters' and the body's. Its own
recursive calls go through the check, so they are swapped too. The cells are
exported as `__camlkit_cells`, appended to the interface as well, so every
unit exports it whatever its `.mli` says.

**The swap is a marker in eval, not a tool.** `[%swap M.f replacement]` and
`[%swap M.f]` to restore. It needed no wire change, a typecheck error lands at
the replacement's own span, and a replacement can hold a watch. The check is
source rather than compiler internals:

```ocaml
let module Camlkit_swap : module type of struct let f = M.f end =
  struct let f = replacement end in ...
```

so a replacement less general than the original (`int list -> int` for
`'a list -> int`) is refused with the compiler's own signature mismatch.

**A fast path was considered and rejected.** Overwriting gives the same answer
only when no reference in the whole program captures the value once: no call
inside its own module, no `let g = M.f`, no `[M.f]` stored at module
initialisation, no `include M`, no signature coercion copying the block, and
nothing a later session phrase captures either. Proving that needs a
whole-program scan of the typed trees and per-session tracking, to save 1-2 ns
per call, and a missed case is the silent stale answer this exists to avoid.

**Recorded because they were easy to get wrong.**

- dune tracks neither OCAMLPARAM nor the ppx binary, so a tree built by an older
  worker is kept as current. The build directory records the worker's digest and
  is discarded when it changes. Found on camlkit loading itself.
- A unit the worker is linked with is left as built. A rewritten `Wire`
  disagrees with the worker's own over its interface, which turned camlkit
  loading its own source from working into refusing. The ppx reconstructs the
  unit's name from the file and dune's `-open` of the wrapper.
- Warning 20 on the call through the cell is fatal in dune's dev profile, so the
  rewritten build turns warnings off; nothing reads them there.
- Cell names carry a digest of the file name: a unit without an interface
  exports its cells, and an `include` of it would otherwise shadow the
  including unit's own.

## Not built

- A function the interface does not export has a cell but cannot be swapped:
  there is no type in scope to check a replacement against. The unit's `.cmt`
  has one.
- Functors, values, functions computed by an expression (`let f = memoize g`),
  externals. The syntax does not give their arity or labels.
- Functions defined in the session.
- The path in `[%swap]` is resolved in the session's scope, not under a local
  `open` inside the phrase.
- A user's own OCAMLPARAM is replaced rather than merged.
