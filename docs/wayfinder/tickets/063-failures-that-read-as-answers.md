---
status: resolved
type: defect
blocked-by: [004, 032]
assignee: lyh
---

# Failures that read as answers

## Symptom

Seen on the installed build, September 2026, while exercising every tool once:

- `describe` of a name the session does not have answers
  `{"status":"ok","phrases":[{"output":"Unknown element.\n"}]}`. The same for
  `Lwt_unix.sleep` in a session that never required it. A caller reading
  `status` concludes the lookup worked.
- `locate` at a position with no identifier answers
  `{"location":"Not a valid identifier"}`: merlin's failure string sits where
  the location object goes, so a caller has to type-test the field.
- A worker that dies mid-phrase, as `exit 3;;` makes it, comes back as
  `isError` with the text "the worker died during evaluation; session state is
  gone" and no structure: not the phrase, and not the exit status, which is the
  one fact that tells an `exit` from a segfault.

Around them the tools report failure four ways: `status: "failed"` with a
`phase` (eval), `status: "rejected"` with a `reason` (a directive), `{"error"}`
(document, expand), and plain `isError` (a dead worker).

## What already exists

Both halves of the fix are in the tree for a neighbour. `Signature` maps
`#show`'s `"Unknown element."` to an error (`lib/signature.ml`), and `describe`
reads the same `#show` without it. `Merlin.documentation` decodes
`"Not a valid identifier"` and the other sentinels into an error for `document`
(ticket 032), and `locate` forwards the same strings raw.

## Direction

Route `describe` through the check `signature` has and `locate` through the
sentinel set `document` has: the laziest fix, two call sites. Whether the four
failure shapes should become one is the separate surface question, and MAP's
"The interface is consistent" note says a deviation needs a reason; none of
these has one recorded. The dead worker's exit status is
already in hand and thrown away: `Session` calls `Unix.waitpid` and ignores
what it returns.

## Resolved

Each of the three is a negative answer or an ended process said as data; the
four failure shapes stay as they are, a question for another ticket.

**describe.** The worker recognises `#show`'s "Unknown element." and answers a
new `Msg.Unknown`, rendered as `{"error"}` without `isError`, like `document`.
The message names the path and says `require` or `signature` reach a package
the session lacks. `Frame.format_version` went to 10.

**locate.** No sentinel set was needed: merlin answers a location as an object
and every failure as a bare string, so any string is the error, in `error`.
The output schema, which declared `file`, `line` and `col` where the result
has always carried `location`, was corrected at the same time.

**A dead worker.** `Session.receive` reaps the worker itself at end of input,
killing first in case it closed its pipe and lives on, and keeps the status.
The result stays `isError`, since the session is gone, and gains `exit_code`
or `signal` (`SIGSEGV`), with the same in the text: "the worker exited with
code 3 during evaluation". A kill already under way when the pipe closes does
not change a status the process exited with.
