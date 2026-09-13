---
status: open
type: defect
blocked-by: [054]
assignee:
---

# A refused swap prints its machinery

## Symptom

A replacement of the wrong type is refused with the compiler's own module
inclusion error, as ticket 054 chose. On the installed build,
`[%swap Camlkit.Supervision.step (fun s _ -> (s, 42))]` answered about a thousand
characters beginning

    Signature mismatch:
    Modules do not match:
      sig val step : 'a -> 'b -> 'a * int end
    is not included in
      sig val step : ... end

and naming the expected type three times before the one line that says what is
wrong: `Type int is not compatible with type Camlkit.Supervision.action`.

The `sig ... end` wrapper is the `let module Camlkit_swap : module type of ...`
the check is built from, which the caller never wrote.

## Direction

Keep the compiler as the judge, since ticket 054's reason for it holds: it knows
generality. Print only the `Values do not match` part and below, which should
be reachable as structure in the typing error rather than by matching text;
confirm that before choosing. The span is already on the whole swap.
