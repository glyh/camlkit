---
status: resolved
type: defect
blocked-by: []
assignee: lyh
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

## Reproduced

On camlkit itself, the same call twice, with the server started from a shell
with no dune on `PATH` and switch adoption off - the shape
[dune cannot see the switch a client did not pass on](039-dune-in-a-bare-environment.md)
is about.

With dune reachable: `ok`, four libraries, `wire` and `camlkit` with the
externals `yojson` and `jsonrpc`.

Without: `partial`, two libraries, `wire` and `mylib` - the test fixture -
both externals gone, and `camlkit` failing with

    Reference to undefined compilation unit `Yojson__Safe'
      Yojson__Safe is not built by this project, so it comes from an external
      library. Load it with the require tool first, then load again.

Every sentence of which is true about the scan's result and false about the
project: `yojson` is declared in `lib/dune`, dune knows it, and it had loaded
seconds earlier. A directory that is genuinely not a dune project still fails
honestly, since there is nothing to scan, which is the case the fallback was
written for.

## Decided

**The evidence stops being discarded.** `dune_top` kept `2>/dev/null` and
mapped any non-zero exit to `[]`. It now keeps stderr and answers with one of
three things rather than a list that meant all of them: `Not_a_project`,
`Dune_failed` carrying what dune said, or `Answered`.

**A dune project is not scanned.** The empty list conflated three situations
and the caller could only read it as the first. Now: no `dune-project` falls
through to the scan, which is what it was for; a dune project whose dune could
not answer is refused, naming what dune said; and dune answering with nothing
left to load is `Ok ([], [])` rather than a reason to scan.

Refused rather than scanned-with-a-field, which is where the ticket had been
leaning. A field beside a wrong answer does not stop a caller acting on the
message, and the message is the part that lies. It also costs little now that
039 removed the common cause, and the refusal names the one thing that fixes
it: in the reproduction above, dune's own `Library "yojson" not found`.

**A named library the project does not build is refused too.** It reached the
same fallback and came back as "no .cma archives under ...", a sentence about
the wrong thing. It now says what the project does build.

**The scan collecting test fixtures** stops mattering for dune projects, since
they no longer reach it, and stays true for the directories where walking the
tree is the whole point. Not otherwise addressed.

## Superseded questions

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

Checked by `scripts/load-check.py`, which cannot live in `dune test` because
the load shells out to `dune top` and dune will not run inside dune. It starts
a second server with no dune on `PATH` and requires a refusal naming dune,
rather than a partial load.
