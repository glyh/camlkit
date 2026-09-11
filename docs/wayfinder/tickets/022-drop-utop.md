---
status: closed
type: prototype
blocked-by: []
assignee: lyh
---

# Removing the utop dependency

## Question

After the worker took over the eval loop, implicit bindings, printers and
loading, what was utop still doing, and was it worth twenty packages?

## Resolution

**Removed.** The dependency tree goes from 22 packages to 2.

| | packages |
| --- | --- |
| with utop | 22, including lambda-term, zed, lwt, lwt_react, mew_vi, uucp, uuseg, uutf, react |
| now | compiler-libs and findlib |

What it was still providing, and what replaced it, all in `worker/toplevel.ml`:

- `UTop.input_name`, a string constant. Inlined.
- `UTop.set_hide_reserved false`, which existed **only** to undo a hook
  `UTop_main` installs from a module initializer. With utop gone there is
  nothing to undo, so the call goes too.
- `UTop.get_message`, rendering an exception. A buffer and
  `Errors.report_error`.
- `UTop.get_ocaml_error_message`, which recovered error locations by
  `Scanf`-ing its own rendering of the error. Replaced by
  `Location.error_of_exn`, which carries the location as data:
  `loc_start.pos_cnum` and `loc_end.pos_cnum` are the byte offsets directly.
  This is strictly better and removes the fragility that bit twice before.
- `UTop.parse_use_file`. `Toploop.parse_use_file` over a lexbuf, with
  `Location.error_of_exn` for the failure.
- `UTop_compat.ldot`, whose whole purpose was the `Longident.Ldot` shape
  change at 5.4. `Longident.unflatten` is identical across versions.
- `UTop_compat.add_cmi_hook`, a wrapper over
  `Persistent_env.Persistent_signature.load`. Its own version branch is at
  5.2, below this project's floor.

**It fixed a live bug.** utop distinguishes "incomplete input" from a syntax
error by raising `Need_more`, so a line editor can prompt for more. Nothing
here can prompt, and we never caught it, so `let x = ` killed the worker
outright and took the session with it. Incomplete input is now an ordinary
parse error with a span. Regression added.

**It also improved the messages.** The location is a field, so the message no
longer repeats it: `Location.msg` carries the body separately, rendered
through `Format_doc.Doc.format`, which matches the standing preference that
an endpoint serves structure rather than prose to parse.

**One thing utop was silently doing had to be replaced.** findlib needs
initialising: `Findlib.init ()` plus the `byte` predicate, without which
every `require` fails and the worker would be offered native archives it
cannot load. Found by the printer test failing.

Verified on OCaml 5.3.0 and 5.4.0, full suite, and against a real compiler
project.

## Note on the earlier fork decision

[Architecture baseline](001-architecture-baseline.md) declined to fork utop
to avoid inheriting compiler-libs churn. This inherits a slice of that churn
directly, which is the honest cost. The mitigation is that every replacement
was checked in both switches and is identical across them; the pieces that do
differ between releases are exactly the ones now avoided rather than wrapped.
