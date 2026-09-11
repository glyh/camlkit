---
status: open
type: research
blocked-by: []
assignee:
---

# How completion works over the protocol

## Question

utop exposes `complete:` and `complete-company:`, answering with
`completion-start:` / `completion:` / `completion-stop:`, or with
`completion-word:` for a unique extension. Establish what the client must
send as input context, what the returned candidates actually contain, and
whether they carry type information or only names.

Read how `src/top/utop.el` in the reference checkout drives it, then
confirm against opam utop. Determines whether completion is a useful MCP
tool on its own or only meaningful with the type lookup that sits in fog.
