---
status: open
type: prototype
blocked-by: [003]
assignee:
---

# Loading libraries into a session

## Question

The protocol has a dedicated `require:<package>` command that calls
findlib, answering `no-such-package:<pkg>` on failure. Determine whether
that is preferable to evaluating a `#require` directive as an ordinary
phrase, how either path interacts with sentinel framing given that
loading a package prints to stdout, and how a load failure surfaces.

This is the codebase exploration half of the purpose, so it matters
beyond convenience.
