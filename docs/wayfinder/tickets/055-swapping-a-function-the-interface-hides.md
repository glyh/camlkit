---
status: open
type: research
blocked-by: [054]
assignee:
---

# Swapping a function the interface hides

## Gap

[Swapping a function in a loaded project](054-swapping-a-function-in-a-loaded-project.md)
gives every top-level function a cell, hidden ones included, but `[%swap]`
refuses a function the unit's `.mli` does not export:

    [%swap Shop.Pricing.round_cents (fun x -> x)];;
    -> cannot be swapped from here: its interface does not export it, so there
       is no type to check a replacement against.

The check is `module type of struct let f = M.f end`, which needs `M.f` in
scope. A helper deep inside a module is often exactly what one wants to swap.

## Direction

The unit's `.cmt`, which dune writes beside the `.cmo`, has the function's type
in the unit's final environment. Two things to find out: whether that type can
be printed so it re-typechecks in the session (a type the interface also hides
cannot be, and that is a refusal worth naming), and whether a replacement
typechecked in the session can use the names the unit sees but the interface
does not. It cannot at run time, so the answer is probably no, and the
replacement is limited to what the interface exports.
