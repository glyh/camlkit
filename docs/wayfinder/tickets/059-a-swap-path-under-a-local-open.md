---
status: open
type: defect
blocked-by: [054]
assignee:
---

# A swap path under a local open

## Symptom

`[%swap]` resolves its path against the session's environment before the
phrase is typed, so a path that only makes sense inside the phrase is not
found:

    let open Shop in [%swap Pricing.tax_rate (fun _ -> 0.)];;

resolves `Pricing.tax_rate` at top level, where it is unbound. As first
committed the unbound case was handed to the compiler as `ignore M.f`, which
typed under the open, so the swap reported `unit` and did nothing: measured,
the receipt still said 120.00. That is now refused with an unbound-value error
telling the caller to write the path in full, which is correct but refuses a
well-typed phrase.

## Direction

Breakpoints already take the environment at a marker from a first typing
pass. The swap could do the same: type the phrase with the marker replaced by
`ignore M.f`, read the environment at that node, and resolve there.
