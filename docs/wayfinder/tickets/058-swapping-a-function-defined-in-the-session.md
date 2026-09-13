---
status: open
type: research
blocked-by: [054]
assignee:
---

# Swapping a function defined in the session

## Gap

`[%swap]` only reaches code load built. A function defined by an `eval` phrase
cannot be swapped, and redefining it leaves earlier phrases calling the old
one, which was the starting point of
[Swapping a function in a loaded project](054-swapping-a-function-in-a-loaded-project.md):

    let f x = x + 1;;  let g x = f x * 10;;  let f x = x + 100;;
    g 1;;   -> 20

## Direction

eval already rewrites phrases for markers, so the same function rewrite could
apply to session definitions, with cells registered in the worker rather than
exported. The question is the surface: `[%swap f ...]` for a session name, or
redefinition itself updating the cell, which is what a Lisp user expects but
changes what `let f` means in every session.
