---
status: resolved
type: defect
blocked-by: [054]
assignee: lyh
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

## Resolved

The structure is there. The constraint raises `Typemod.Error` with
`Not_included`, whose explanation holds one incompatible item,
`Core (Value_descriptions {got; expected; symptom})`. `Swap` records the
location of every check it builds in the phrase, and a typing error at one of
them with exactly that shape is printed as the path and
`Includecore.report_value_mismatch` alone:

    Error: Swaplib.length cannot be swapped for this replacement.
    The type int list -> int is not compatible with the type 'a list -> int
    Type int is not compatible with type 'a

The mismatch already names both types, so a "has type" pair before it was
tried and dropped as the repetition this ticket is about. Anything else at
that location, or a module constraint the caller wrote, keeps the compiler's
full error. The compiler is still the judge; only the printing changed.
