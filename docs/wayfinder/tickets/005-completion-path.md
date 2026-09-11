---
status: closed
type: research
blocked-by: []
assignee: lyh
---

# Exploring the environment: describe, not complete

## Question

Probed directly in the worker prototype. `UTop_complete.complete
~phrase_terminator ~input` returns a start offset and a list of pairs.

**The second element is not type information.** It is an insertion
suffix: `#requ` completes to `require` with suffix `" \""`, and ordinary
identifiers carry an empty one. So candidates are **names only**.

It is context-aware mid-expression: `let z = x + 1 in Strin` returns
`String` and `StringLabels` at offset 17. Directives complete. But `x.`
where `x : int` returned 132 module names rather than anything
type-directed, so it falls back rather than using the type of the prefix.

## Resolution

**Expose a describe tool, not completion.** Completion is designed for a
human typing character by character, and returns names without types. An
agent does not type. It asks what exists in a module and what shape those
things have, which is a different question.

**The toplevel already answers it, so this costs almost nothing.** The
`#show` directive returns a full signature with types, and works on
user-defined modules as well as stdlib:

```
#show Option;;
module Option :
  sig
    type 'a t = 'a option = None | Some of 'a
    val none : 'a t
    val some : 'a -> 'a t
    val value : 'a t -> default:'a -> 'a
    ...
  end
```

`#show_val List.map` gives `val map : ('a -> 'b) -> 'a list -> 'b list`
and `#show_type option` gives `type 'a option = None | Some of 'a`.

So the describe tool is an evaluation of `#show <path>` whose rendering is
returned. No walking of `Env`, no per-candidate type lookup, no new
machinery. Verified in the worker prototype.

The output is formatted OCaml signature text rather than structured data.
That is acceptable: signature syntax is exactly what an agent reads
natively, and structuring it would mean reimplementing the printer.

Rejected enriching completion with types, which keeps a prefix interface
the agent has no use for and costs a lookup per candidate, on prefixes
that returned as many as 72 results. Rejected exposing raw completion as
well, for now; nothing has asked for prefix search.
