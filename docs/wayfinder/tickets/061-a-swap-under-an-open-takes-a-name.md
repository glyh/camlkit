---
status: closed
type: defect
blocked-by: [054, 059]
assignee: lyh
---

# A swap under an open takes a name

## Symptom

A swap sent as a phrase of its own is bound to `()`, so it takes no implicit
`_N` name and renders only the line saying what it did. The same swap under a
local open or a local module is not recognised as that phrase shape, so it
renders as a unit value and uses up a name:

    [%swap Camlkit.Render.bytes (fun _ -> "SWAPPED")];;
    -> swapped Camlkit.Render.bytes

    let open Camlkit in [%swap Render.bytes (fun _ -> "SWAPPED")];;
    -> val _0 : unit = ()
       swapped Render.bytes

Measured on the installed build after
[A swap path under a local open](059-a-swap-path-under-a-local-open.md), which
made the second form work at all. Cosmetic: the swap happens either way.

## Direction

`Swap.rewrite`'s `structure_item` case matches only `Pstr_eval` of a bare
marker. Looking through `Pexp_open` and `Pexp_letmodule` bodies down to a
marker would cover both forms. The same then holds for a sequence ending in a
swap, which is a question of where to stop rather than a new mechanism.

## Declined

Won't fix. The swap happens and says so in both forms. The extra line is a
`unit` binding, which is what the phrase is, and it costs one line. Looking
through `open` and `let module`, and then deciding where a sequence stops,
would add rules to the rewrite to hide something that is true.
