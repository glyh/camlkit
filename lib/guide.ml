(* The manual behind each tool's description. A description is loaded into
   every session that loads the tool, so it says when to reach for the tool and
   the one mistake that would make a call wrong. Everything else a caller may
   need - limits, edge cases, what a field means - is here, read through the
   help tool when a caller needs it. See docs/wayfinder/tickets/062. *)

let manual = [
  "eval", {|Evaluates OCaml phrases in a session. State persists between calls.

Several phrases per call, and nothing runs unless every one of them parses and
typechecks, so a failure leaves no partial state behind. That also means a
phrase cannot use something an earlier phrase in the same call put on the
search path: put such a change in its own call.

Directives such as #require are rejected. Loading a library is require or load;
showing a signature is describe.

check: typecheck against the session and stop. Each phrase's type is reported,
nothing runs, the session is unchanged and no implicit _N name is used up. The
rendering then says val f : int -> int with no value.

cost: wall_ms and allocated_bytes per phrase. Both cover compiling, running and
printing the phrase, so there is a floor of roughly 70 kB and a fraction of a
millisecond, and printing a large value costs far more. Put the work in a loop
inside the phrase and the floor stops mattering: 100000 refs measure 1.61 MB
against 1.6 MB expected. The allocation is a count and sound; the time is one
un-repeated run of toplevel-compiled bytecode, not a release build.

autorun: a bare expression whose type is a promise is run rather than returned.
The default is ["lwt", "async"]; a session without those libraries is
unaffected. Pass [] to get the promise itself. The call's rules are echoed in
autorun only when they differ from the default, and a rewritten phrase names
its rule in ran.

Markers, for live debugging:
- [%break "name"] stops the phrase there. Its locals are bound under bp_ names;
  use inspect to see them and continue to resume or abandon.
- [%watch "name" expr] records every value of expr and returns it, without
  stopping. A phrase's result carries what its watches recorded during that
  phrase, in watched; consecutive equal values are stored once with a count.
- Both are compiled into the code holding them and keep firing whenever it
  runs. markers lists them and disarms them.
- [%swap Module.f replacement] makes every caller of a top-level function in a
  project brought in by load call the replacement, callers inside its own
  module included. [%swap Module.f] puts the original back. Only functions
  swap, including one computed by an expression such as let pp = Fmt.list item;
  a value, an external, a function inside a functor and anything load did not
  build cannot, and the error says which. The replacement must have the
  function's type, at least as general.

Result fields, each absent when it has nothing to say: rendering (what the
toplevel printed, where bindings are read), warnings, output (what the phrase
printed, ending with [output truncated, N more characters] past the limit),
ran, watched, cost, and checked when the call only typechecked.|};

  "describe", {|Shows the signature of a module, value or type as a session sees it,
including modules defined during the session. For an installed package the
session has not loaded, signature answers without a session.|};

  "require", {|Loads findlib packages into a session, making their modules available to
later calls. Packages with C stubs work from a bare environment. A load that
resets the session puts back the packages required before it.

Result: loaded, and failed with each library and its error.|};

  "load", {|Loads a dune project's own libraries into a session.

path is the project root, the directory holding dune-project, or a directory
inside its _build. It defaults to the project the server was started in.
libraries picks some; omit it to load everything found. External dependencies
come along, so they need no require.

The project is built for the session in _build/camlkit, beside the user's own
build, through the worker as a ppx, so that eval's [%swap] can replace its
functions.

Pass reset after rebuilding: loading a changed archive into a session holding
the old one fails on an interface mismatch. Packages required earlier are put
back after the reset.

The worker must be built with the same OCaml version as the project, because
bytecode is version-locked.|};

  "reset", {|Discards a session and starts it clean: bindings and loaded packages are
gone. Use it to get back to a known state rather than inventing a new session
name, which leaves the old toplevel running.

code is evaluated in the fresh toplevel in the same call, which is how a
preamble of helpers is put back with no window where the session is empty; the
result is then an eval's. Nothing is remembered: the next reset empties that
too unless it carries the code again.|};

  "continue", {|Resumes a phrase parked at [%break], or abandons it.

The result is an ordinary eval result: what the rest of the phrase printed and
what it came to, or another stop at a second breakpoint.

abandon raises inside the phrase instead of resuming, so the rest does not run
but whatever it set up to release on the way out is released.

id picks the parked phrase; omit it when the session has exactly one.|};

  "inspect", {|Shows what the markers have gathered, without resuming anything.

For a parked phrase: its locals, bound again under their bp_ names (bound, each
with its type), which recovers an earlier stop's values after a later stop
overwrote them. Locals that could not be bound are in skipped with the reason.

For watches: each site's recent trail. An eval result reports only what its own
phrase recorded; this is the history. Works with nothing parked, as long as
something has been watched.|};

  "markers", {|Lists the breakpoints and watches a session knows, and the swaps in force.

Each marker has name, kind, armed and hits; hits is the site's lifetime count,
not this call's. A marker cannot be removed, because it is compiled into its
code, so one in a function called often keeps firing until disarmed or the
function is redefined. A disarmed marker is still reached and does nothing.

disarm and arm take names. A name can be written in several places; each place
is a site with its own id, shown with the definition and line it is in, and
disarm_sites and arm_sites act on one. Writing a name again adds a site, which
starts armed, and the eval that adds it warns with the site and the total. A
name cannot be both a breakpoint and a watch.

swapped lists functions a swap replaced, by the path it was written with;
restore puts them back. unknown lists names passed that the session has not
got, so a typo is not silent.|};

  "locate", {|Finds where the name at a position is defined, from source: nothing is
built or loaded. line is 1-based, col 0-based.|};

  "type_at", {|The type of the expression at a position, and of each enclosing expression,
innermost first, each with the range it covers. From source: no build, no
session. Enclosings are strictly nested, and exact duplicates merlin emits are
removed.|};

  "outline", {|What a source file defines: every value, type, module and class, with its
kind and position. selection is the name's own span, which is the position
uses or locate on that name needs.|};

  "uses", {|Every occurrence of the name at a position.

scope is project (the default) or buffer. Project scope needs dune's index,
and merlin silently answers from the one file without it, so the index is
built first (about 0.2 s on a built project). If it cannot be built, or the
project's compiler predates OCaml 5.2 and writes no occurrence data, the result
carries complete: false and a caveat rather than looking whole.|};

  "search_type", {|Finds values by type, in scope at a position, such as "int -> string" or
"'a list -> 'a option". Results are ranked best first.

Qualify type names: merlin matches against its own environment, not the
buffer's, so write "Core.term -> string" even in a file that opens Core, or
nothing is found. limit counts results after duplicates are removed.|};

  "expand", {|The code a ppx generated at a position, as source: what [@@deriving ...] or a
[%extension] expands to. From the file, with no build and no session.

Put the position on the deriver name inside [@@deriving ...], or on the
[%extension] itself; a position on the type or expression it is attached to
finds nothing, and error says so. A structure-level extension such as
let%test_module may not expand where an expression one does. deriver is the
range of the node the code came from.

When the generated names are all you want and the project builds, describe on
the built module is cheaper.|};

  "diagnostics", {|Errors and warnings for one file from merlin, in milliseconds.

source asks about an edit not written to disk yet; positions are then into that
text. The file is still named, because that is how the project configuration is
found.

This is not a build. It types one file against what is already compiled around
it, so it cannot tell that a dependency needs rebuilding, and a clean answer is
not a passing build.

errors and warnings come apart, each absent when empty, each entry with its
message and range.|};

  "document", {|The documentation comment on a name, as written, from source.

Ask exactly one way. identifier finds anything in scope in that file, its
dependencies included, which is usually what you want. line and col find
whatever is at a position, which is how to reach a name defined in the file
itself. Both, or neither, is refused.

The text is odoc markup, unrendered: {!Bytes.t} and {b bold} are the comment's
own syntax. A name with no comment, or not in scope, comes back in error.|};

  "signature", {|The signature of a module, value or type in an installed findlib package,
read from its compiled interfaces: no session, nothing linked, none of its code
run.

package defaults to the path's first component. When that guess was used the
result carries guessed: true, and a failure with it set is worth retrying with
the package named, such as lwt.unix for Lwt_unix; one without it is not.

For what a session already has, or modules defined in a session, use describe.|};

  "context", {|The opens that put a session in a source file's context, so a fragment lifted
out of that file resolves the way the file does.

Evaluate the returned code once, or pass it to reset: an open is ordinary
session state. It answers from source and needs no session, but the modules it
names exist only in a session that has loaded the project. A file in no
wrapped library gets only its own opens, because a session cannot name its
module.|};
]

let topics = List.map fst manual
