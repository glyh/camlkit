---
status: resolved
type: decision
blocked-by: [027]
assignee: lyh
---

# Reading a name's documentation

## Question

Nothing on the surface returns a docstring. `#show` drops them, so neither
`describe` nor
[Module signatures without loading](026-signatures-without-loading.md) can
reach one, and `type_at` answers with a type rather than with what a function
does or what it raises. merlin has a `document` command; the fog entry asked
whether it was worth a tool.

## Decided

**Worth a tool.** It is the only question on the surface that nothing else can
answer, and merlin does all the work: a branch in the existing source-query
dispatch, a schema, and one pure function for the answers.

**Two ways to ask, because merlin has two and they fail differently.** A line
and column asks about whatever is at that position, which is how to reach a
name defined in the file being read. An `identifier` asks about any name in
scope in that file, which is what an agent usually has: a name, and no idea
where it appears.

**The caller's position is never used with an identifier.** This was measured,
not assumed. merlin infers which namespace to search from the node under the
cursor even when the name is given outright: `from_string` in
`src/analysis/locate.ml` calls `infer_namespace`, which inspects the browse
tree at the cursor, and `src/analysis/env_lookup.ml` maps that context to a
namespace list, where `Module_path -> [`Mod]` is the narrow one. So asking
about a value while the cursor sits inside a module path searches modules
alone and answers "Not in environment" about a name that is plainly in scope.
Reproduced in `lib/merlin.ml` at 95:20, inside `Yojson.Safe.from_string`:
`String` resolved, `List.map` and `Yojson.Safe.t` did not.

Column zero is never inside a module path, a constructor or a record label -
the three narrow contexts - so the permissive context applies and every
namespace is searched. Measured at three positions in a real project file: a
value, a module, a type and a constructor all resolved at every one. The
server therefore supplies 1:0 itself.

What that leaves is an environment limit rather than a namespace one: a name
defined in the buffer at or after that point is not in scope there. That is
what the position form is for, and the tool description says so.

**The sentinels are decoded, not passed on.** Every outcome of `document`
arrives as `class: return` carrying a plain string, so "No documentation
available" and "Not in environment 'X'" read exactly like a docstring. The set
is closed and listed in merlin's `src/commands/query_json.ml`;
`Merlin.documentation` matches it and returns an `error` field instead of a
`documentation` one. It is pure, so it is tested without merlin. `File_not_found`
carries an arbitrary message and cannot be recognised, so it is shown as
documentation; it means the interface holding the name is missing, which is
worth seeing.

**The markup is passed through unrendered.** A comment comes back as odoc
source: `{v ... v}`, `{ul {- ... }}`, `{b ...}`, `{!Bytes.t}`, `[inline code]`.
Rendering it would mean owning a second parser for no gain, since it reads
perfectly well as it stands. The tool description says what the braces are so
the markup is not mistaken for noise.

**Not merged into `signature`.** merlin needs a buffer whose environment holds
the name, so a package that nothing in the project references stays out of
reach; `signature` reaches it but reads interfaces, which carry no comments.
Joining the two would mean reading the installed `.mli`. Left in the fog.
