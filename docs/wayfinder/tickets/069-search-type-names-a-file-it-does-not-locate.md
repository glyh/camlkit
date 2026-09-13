---
status: open
type: defect
blocked-by: [027]
assignee:
---

# search_type names a file it does not locate

## Symptom

`search_type` for `'a list -> 'a option` from a file in this project answered
entries such as

    {"file":"list.mli","start":{"line":88,"col":0},"name":"List.nth_opt",...}

A bare `list.mli` is not a path any other tool accepts: `locate`, `type_at`,
`document` and `outline` all take an absolute file, which is the argument
ticket 051 found to matter. The position is exact and cannot be used.

## Direction

Check what merlin's `search-by-type` gives before choosing. If it has the full
path, stop dropping it; if not, `name` is already a qualified path, and
`document` and `signature` take names, so the file field may be the one to drop.
