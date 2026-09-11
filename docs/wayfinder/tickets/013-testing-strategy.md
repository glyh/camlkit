---
status: closed
type: grilling
blocked-by: []
assignee: lyh
---

# Testing strategy

## Question

The suite tests only pure functions. The session driver is where the real
bugs will live, and every quirk found so far was a timing behaviour: the
stdout scheduling race, SIGINT recovery, stdin theft.

## Resolution

**One tier. Integration tests spawn a real utop inside the default
`dune test`.** utop is a hard dependency of the project, so it is always
present, and a spawn costs about a second.

Rejected putting them behind a separate dune alias. It would keep the
inner loop fast, but the tier covering the actual risk is then the tier
nobody runs.

Rejected replaying recorded protocol transcripts against a fake child. It
tests our assumptions rather than utop, and none of the quirks found so
far are expressible as a transcript. Each is a scheduling or signal
behaviour that only appears against the real process.

Consult the `ocaml-alcotest` skill for anything touching the suite.
