---
status: closed
type: grilling
blocked-by: [006]
assignee: lyh
---

# Let a session opt out of hermetic spawn

## Question

Sessions are hermetic, so results do not vary with whoever's machine they
run on. Note this is no longer a pair of flags: the worker simply never
calls utop's init-file path, which was confirmed by pointing
`XDG_CONFIG_HOME` at a config directory containing an `init.ml` and finding
its binding unbound inside a session.

The cost is unchanged. A user's toplevel printers live in `init.ml`, so
values from their own libraries print as `<abstr>` in a session, which is a
real behavioural difference from typing `utop` yourself.

Decide how a caller opts back in: whether it is a boolean on session
creation, an explicit init file path, or server-level configuration rather
than per-session. Opting in now means the worker deliberately evaluating
that file, so decide what happens when it fails to load. Also whether an opted-out session should be
marked as such in anything it returns, since its results are no longer
reproducible elsewhere.

Depends on the tool surface, which decides how a session is created and
what parameters it takes.

## Resolution: not worth doing

Closed without implementing. Its premise was eaten twice.

First by [Automatic toplevel printers](018-automatic-toplevel-printers.md):
printers declared with `[@@ocaml.toplevel_printer]` are installed regardless
of any init file, which was most of what this ticket was protecting.

Then by looking: there is no `~/.config/utop/init.ml` and no `~/.ocamlinit`
on the machine this is built for, so there is nothing to opt back into. What
remains is imperative `#install_printer` calls in a file that does not exist.

Reopen if someone turns up who has such a file and misses it.
