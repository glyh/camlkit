---
status: open
type: grilling
blocked-by: [006]
assignee:
---

# Let a session opt out of hermetic spawn

## Question

Sessions spawn with `-init /dev/null -no-autoload` so results do not vary
with whoever's machine they run on. The cost is that a user's toplevel
printers live in `init.ml`, so values from their own libraries print as
`<abstr>` in a session, which is a real behavioural difference from
typing `utop` yourself.

Decide how a caller opts back in: whether it is a boolean on session
creation, an explicit init file path, or server-level configuration
rather than per-session. Also whether an opted-out session should be
marked as such in anything it returns, since its results are no longer
reproducible elsewhere.

Depends on the tool surface, which decides how a session is created and
what parameters it takes.
