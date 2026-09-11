---
status: open
type: research
blocked-by: []
assignee:
---

# Progress on a long operation

## Question

An evaluation, a load, or a build can run for many seconds with the caller
seeing nothing until it finishes or the deadline fires. MCP has progress
notifications for exactly this.

Establish what the current revision requires: how a client opts in, what a
progress token is, and whether a notification may be sent for a request that
then fails. Then decide which operations report - `load` has natural
milestones, one per archive, and an evaluation has none.

Worth weighing against the capture file, which already lets the server read
partial output at any time; progress may be better spent on `load` and on a
build than on `eval`.
