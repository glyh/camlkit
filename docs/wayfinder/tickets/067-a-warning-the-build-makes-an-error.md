---
status: open
type: research
blocked-by: [042]
assignee:
---

# A warning the build makes an error

## Symptom

`diagnostics` on `wire/frame.ml` with the source `let unused y = 1` put
`Error (warning 27): unused variable y.` under `errors`, beside a real type
error, with nothing but the message's prefix to tell them apart. Ticket 042
splits warnings from errors on merlin's `type`, and dune's development profile
promotes this warning, so merlin files it as an error.

That is true of the build: it would fail. But a caller fixing errors in order
cannot tell "this does not typecheck" from "this is a lint the profile is
strict about" without parsing the message, and the second is usually the one
to leave for last.

## Open

Whether this needs anything. The prefix is the compiler's and stable, so a
`warning: 27` field on such an entry would be structure restating text, which
ticket 004 says is not worth its bytes. Record a caller being misled by it
before adding one; decline otherwise.
