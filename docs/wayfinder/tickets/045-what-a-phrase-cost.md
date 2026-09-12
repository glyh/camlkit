---
status: resolved
type: research
blocked-by: []
assignee: lyh
---

# What a phrase cost

## Question

`eval` says what a phrase produced and never what it cost. An agent asked
whether one implementation allocates less than another, or whether a function
is slow, has nothing to read: it can time the round trip from outside, which
measures the round trip, or it can write its own `Gc.quick_stat` calls around
the code, which is a phrase about measuring rather than a measurement.

Two numbers would answer most of it: wall clock for the phrase, and words
allocated by it.

## Why it is nearly free here

[A ceiling on a phrase's heap](030-heap-ceiling.md) already reads
`Gc.quick_stat` on a Gc alarm armed only while a phrase runs, for the heap
ceiling. The same call before and after gives allocation:
`minor_words + major_words - promoted_words` is the standard sum, and
`quick_stat` deliberately does not walk the heap, which is why 030 chose it.
`top_heap_words` comes along for peak heap.

`Unix.gettimeofday` around `execute_phrase` gives the clock. Both are inside
the per-phrase loop in `worker/eval.ml`, which is where the offsets for
captured output are already computed, so the place to put them exists.

## Prior art

From `mina-agent`, where `mina_agent/perf.py` measures a Mina workload's
allocation from the runtime's own counters under `OCAMLRUNPARAM=v=0x400`,
reading `allocated_words`, `minor_words`, `promoted_words`, `major_words` and
`top_heap_words` out of the dump the runtime prints at exit, with wall clock
and peak RSS from `/usr/bin/time`. That route exists because it measures a
whole process it does not link. Inside the worker the same counters are a
function call, and there is no process exit to wait for.

## Decided

**Opt-in, not reported when notable.** The ticket's first open question was
whether to report always above a threshold. `cost: true` on `eval` instead, the
way `check` is: most phrases cost nothing worth a number, a threshold is a
constant nobody can pick for every caller, and a caller that is not measuring
should not pay two numbers per line.

**Wall clock and allocated bytes, nothing else.** `top_heap_words` is left out:
it is cumulative for the process, so it says what the session has ever reached
rather than what this phrase needed, and a field that has to be explained away
is not worth its bytes.

**A resumed phrase is not measured.** It already ran up to its stop, so a
reading would cover the remainder rather than the phrase, and the call that
asked was a different one.

## Measured, and the first attempt was wrong

`Gc.quick_stat` alone gives numbers that look plausible and are not.
`Array.make 1000` measured as 3.2 MB and `String.make 10000` as nothing at all:
`quick_stat`'s `minor_words` lags the young region, so a small allocation reads
as zero until a minor collection, and a large allocation skips the minor heap
entirely while `major_words` only settles at a major slice.

A minor collection before each reading fixes both. Against a standalone program
with known answers:

| phrase | measured | expected |
| --- | --- | --- |
| `Array.make 1000` | 1303 words | 1001 |
| `String.make 10000` | 1278 words | 1252 |
| `List.init 1000` | 3026 words | 3000 |
| `1 + 1` | 26 words | 0 |

The collection is only paid for when the call asked, and the clock starts after
it, so it does not land in the timing.

**The floor is real and is in the description.** The reading covers compiling,
running and printing the phrase, because `Toploop.execute_phrase` does all three
and there is no seam between them. An empty phrase measures 70 to 300 kB and a
fraction of a millisecond, and printing a large value costs far more than that:
`Array.make 1000` through the tool reads 2.7 MB, nearly all of it printing a
thousand elements.

Put the work in a loop and the floor stops mattering, which is what the
description points at. 100000 refs measured 1.61 MB against 1.6 MB expected,
within 0.6%, and the same loop over an unboxed int measured 72 kB, which is the
floor.

## Open

**Whether the floor should be subtracted.** It could be measured once per
session and taken off, which would make small phrases readable. Not done: the
floor is not constant, since it depends on what the phrase compiles to and what
its value prints as, so subtracting a single number would replace a visible
overhead with an invisible error.

**Whether the wall clock earns its place at all.** Allocation is a count and
barely moves between runs; the clock is one un-repeated run of code the toplevel
compiled, and it invites the conclusion that a release build would behave the
same way. It is reported because it is the question people ask, and the
description says plainly what it is not.

Covered by "cost is opt-in" in the worker suite: nothing is measured unless
asked, a loop allocating a known 1.6 MB measures as that, and a loop allocating
nothing stays at the floor.
