---
status: open
type: grilling
blocked-by: []
assignee:
---

# Should Lwt and Async expressions auto-run

## Question

The last item from the audit of what `UTop_main` does and we do not.

utop rewrites a phrase whose value is an `_ Lwt.t` or an Async deferred so
that it runs and yields the result, rather than handing back a promise.
That is `UTop_main.rewrite`, which is internal, and it is gated on
`UTop.auto_run_lwt` and `UTop.auto_run_async`. Roughly forty lines.

The question is whether an agent wants it. Arguments both ways: it matches
what a person gets from utop and makes exploring Lwt-based code far less
tedious, but it silently changes the type of what comes back, which for a
consumer reasoning about types rather than reading a terminal may be worse
than explicit.

Mechanically it is available: the worker runs no event loop of its own, so
`Lwt_main.run` works inside it natively. That was checked when deciding
against `lwt_eio`, see
[Worker linked to utop replaces the subprocess protocol](014-worker-architecture.md).

Everything else from that audit is either done or a deliberate omission:
`Location.input_name` is now set, init files and history stay skipped for
hermeticity, and `Sys.catch_break` has an equivalent in the worker's own
SIGINT handler.
