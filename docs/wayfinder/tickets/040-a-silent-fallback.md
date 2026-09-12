---
status: open
type: defect
blocked-by: []
assignee:
---

# A failed dune top degrades in silence

## Symptom

`load` asks `dune top` for a project's archives and falls back to scanning the
build tree when that produces nothing. The fallback is invisible. A caller sees
a load that reports `ok` or `partial` either way and cannot tell which route
answered, so a wrong answer reads like a complete one.

What it costs, from the failure in
[dune cannot see the switch a client did not pass on](039-dune-in-a-bare-environment.md):
the scan found `wire` and `mylib`, a test fixture that is in the build tree
and has no business in a session, and missed every external the project
depends on. The error it then reported named `Jsonrpc` and advised `require`,
which is a true sentence about the scan's result and a false one about the
project.

## Cause

Two places drop the evidence. `dune_top` runs the command with `2>/dev/null`
and maps any non-zero exit to the empty list, so the reason is discarded at the
point where it is known. `load` then treats an empty list as "not a dune
project" and scans, which is the right response to one of the two things an
empty list can mean.

## Not yet decided

**What a caller should be told.** The project conventions say a failure names
the failing thing in a field, and that a field with nothing to say is absent.
So probably: nothing when dune answered, and when it did not, what dune said
and that the answer came from a scan. That is a field on the load result, not
prose in the error text, since the caller's next move differs - a scan that
missed the externals is worth retrying after fixing the environment, and a
genuine non-dune directory is not.

**Whether the scan should still run.** It is the right answer for a directory
that is not a dune project at all, which is what the fallback was for. It is
the wrong answer for a dune project whose `dune top` failed, where scanning
produces a confident, wrong result. Distinguishing them is already possible:
`is_dune_project` is checked before the command runs.

**Whether `mylib` in the result is a second bug.** The scan walks the whole
build tree for `.cma` files, so it collects test fixtures and anything else
built. Harmless when the scan is a last resort for a small directory, noise
when it stands in for a real project.
