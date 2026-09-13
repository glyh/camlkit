---
status: open
type: research
blocked-by: [054]
assignee:
---

# Swapping a function inside a functor

## Gap

The load rewrite in
[Swapping a function in a loaded project](054-swapping-a-function-in-a-loaded-project.md)
leaves functor bodies alone, so `Make (X).h` cannot be swapped.

A cell hoisted to the unit is shared by every application of the functor, so
one swap would change `Set.Make(Int).add` and `Set.Make(String).add` together,
and there is no path naming one application: `[%swap IntSet.add ...]` goes
through an alias to a module the functor built at run time.

## Direction

A cell per application, created in the functor body and exported in the
result, would give each application its own `__camlkit_cells`, and the
existing longest-prefix lookup would then find `IntSet.__camlkit_cells`. That
changes the functor's result signature, which a constraint on the application
(`module S : Set.S = Set.Make (Int)`) would strip. Find out how often that
breaks before choosing.
