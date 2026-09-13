---
status: resolved
type: defect
blocked-by: [054]
assignee: lyh
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

## Decided

**As directed, and every swap is probed, not only an unbound one.** Before
expansion the phrase is typed once with each swap as `ignore <path>`, and the
environment at each is read with `Breakpoint.marker_envs`. Probing only when the
path fails at top level would still be wrong when a top-level module and one
under the open share a name, where the open wins.

**The probe strips the other markers too:** a watch becomes its expression and
a breakpoint `()`. Otherwise any phrase holding one would fail the probe for a
reason that has nothing to do with the swap.

**A probe that fails keeps the session's environment**, which is the old
behaviour and the old refusals. An unbound path fails the probe, so its error is
still "Unbound value", now without the sentence about opens.

**Aliases are normalised before the cell array is read,** so
`let module S = Swaplib in [%swap S.rate ...]` works: `S` is a local name
`Toploop.eval_value_path` cannot evaluate, and `Swaplib` behind it is global.

Tested under a local open, through a local module, and beside a watch in the
same phrase.
