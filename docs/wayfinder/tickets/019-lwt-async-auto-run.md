---
status: closed
type: grilling
blocked-by: []
assignee: lyh
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

## Resolution

Implemented as `worker/autorun.ml`, following utop's approach: type the
structure, and for each bare expression whose type is `Lwt.t` or
`Async.Deferred.t`, rewrite it to run rather than to return.

**Two orderings matter and both were wrong at first.** The rewrite needs the
typed tree, so it happens inside the typing pass, where
`Typemod.type_toplevel_phrase` already hands back a `Typedtree.structure`. And
it must run *before* bare expressions are given implicit `_N` names, because
after that a phrase is a `let` rather than a `Pstr_eval` and there is nothing
left to match. A rewritten phrase is typed again so the environment the next
phrase sees is right, its type having changed from a promise to the value.

**Only bare expressions are rewritten.** `let p = Lwt.return 7` keeps its
promise, which is what someone binding it meant. Same as utop, and tested.

**Configurable per session, as a list of rule names.** A list rather than an
enum so another rule can be added without changing the shape callers pass.
Both are on by default, matching utop; an empty list gets the promise itself.
An unknown name is refused with the list of known rules rather than silently
ignored.

**No spawn parameter was needed.** Each rule self-gates on the expression's
type *and* on the runner existing in the environment, so a session that never
loads Lwt is unaffected whatever the setting. The setting exists for the case
where the library is loaded and the caller wants the promise anyway.

`Ast_helper.Exp.fun_` is gone in current OCaml, which is what utop needs cppo
for. `Exp.function_` with a `Pparam_val` is identical on 5.3 and 5.4, so no
version branch is needed here.

Async is untested: nothing in reach uses it. The rule mirrors utop's, and the
runner it calls, `Async.Thread_safe.block_on_async_exn`, starts the scheduler
around the work rather than waiting on a running deferred, which is why it
takes a thunk.

## Follow-up: the setting and the rewrite are both reported

From a session exercising this end to end. Three things cost effort that the
result should have saved:

- The off switch was hard to express. An omitted argument means "leave it
  alone", a list means "replace it", and `[]` means "off", three meanings
  over one field, with nothing but the description to tell them apart.
- Stickiness was invisible. Confirming that a setting had persisted took a
  second probe expression, because no result said what the setting was.
- The rewrite was silent. Nothing distinguished a plain value from a promise
  that had been run for you; only the type hinted at it.

**Both gaps are now fields rather than prose.** Every completed eval carries
`autorun`, the rule list in force after the call, which also makes the empty
list observable instead of something to infer. Each phrase carries `ran`, the
rule that rewrote it, absent when nothing did, and the transcript gains one
line saying the expression was run rather than returned.

Which rule fired is known only from the first typing pass: by the second, a
bare expression has become a `let` and nothing matches, so `Autorun.rewrite`
returns the name alongside the rewritten structure and `eval` carries it
through `bind_expressions` to the phrase record.

The three input meanings stay as they are. Omission has to mean "leave it
alone" for a session setting, and the alternative is a second argument for
turning it off, which is more surface for the same thing. The description now
names all three cases explicitly instead of mentioning the empty list in
passing.
