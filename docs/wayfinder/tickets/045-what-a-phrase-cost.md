---
status: open
type: research
blocked-by: []
assignee:
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

## Open

**Whether it is reported at all, or only when notable.** The conventions say
a field with nothing to say is absent, and most phrases cost nothing worth a
number: a `let` of a constant, an `open`, a definition. A threshold - report
above some milliseconds or some words - keeps a transcript from growing two
numbers per line it does not need. What the threshold is, and whether a
caller can ask for the numbers unconditionally, is the decision.

**Whether it is honest.** A single run of a phrase in a toplevel is not a
benchmark: the first call pays for lazy initialisation, the code is not the
code a `dune build --profile release` would produce, and nothing is repeated.
Allocation is the sound half, because words allocated is a count rather than
a timing and barely varies between runs. Wall clock is the half that invites
a wrong conclusion, and the description has to say so or the tool becomes a
benchmark that lies - the same objection
[Diagnostics without a build](042-diagnostics-without-a-build.md) has to
answer about not being a build.

**Peak heap.** `top_heap_words` is cumulative for the process, not for the
phrase, so it says what the session has ever reached rather than what this
phrase needed. Either it is reported as that, or it is left out.

**Against the whole thing.** An agent that wants a real measurement can
write the loop itself in a phrase, and gets to choose the repetition count
while it does. What this buys is the cheap case: noticing that something cost
far more than expected without having decided in advance to measure it.
