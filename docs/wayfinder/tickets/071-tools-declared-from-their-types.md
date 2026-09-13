---
status: open
type: research
blocked-by: [002, 004, 062]
assignee: lyh
---

# Tools declared from their types

## Question

[Output schemas drift from results](070-output-schemas-drift-from-results.md)
found `locate` declaring fields it never sent and `eval` declaring none of the
fields a failure carries. The spec makes that more than untidy: when a tool
declares an `outputSchema`, servers **MUST** send `structuredContent` that
conforms to it (2026-07-28, server/tools). The input side drifts the same way:
`lib/tools.ml` declares each argument, and `bin/main.ml` reads it again by hand
with `arg_string args "path"`.

A test would catch drift only in the results the suite happens to produce. The
question is how to make drift a compile error instead.

## The model: the C# SDK

The official C# SDK (v2) derives a tool from one method. `[McpServerTool]`
names it and carries `Title` and the behaviour hints `ReadOnly`, `Destructive`,
`Idempotent` and `OpenWorld`, which become the tool's `annotations`. The input
schema is generated from the parameters, with `[Description]` on each, and
arguments are deserialized for the method. With `UseStructuredContent`, the
output schema is generated from the return type and the return value is
serialized into `structuredContent`; `OutputSchemaType` names the type when the
method returns a raw `CallToolResult` to set `isError` itself.

OCaml has no reflection, so the equivalent is a deriver on types, and a typed
`Tool.make` joining them:

    type describe_args = {
      session : string; [@default "main"] [@doc "Session name, default main."]
      path : string;    [@doc "Such as List or List.map."]
    } [@@deriving mcp]

    type describe_result =
      | Signature of { phrases : phrase list }
      | Unknown of { error : string }
    [@@deriving mcp]

    let describe = Tool.make ~name:"describe" ~read_only:true
        ~doc:"Show the signature of ..." describe_args describe_result handler

`Tool.make`'s type makes the handler take `describe_args` and return
`describe_result`, so an argument read under another name or a result field the
schema lacks does not compile.

## Rejected

**`ppx_deriving_jsonschema`**, the one existing deriver for JSON Schema. It
depends on `melange` and `server-reason-react`, which is the kind of weight
[Removing the utop dependency](022-drop-utop.md) took out. `ppxlib` is already
installed; a deriver emitting a codec and a schema is written here.

**A test comparing keys with schemas**, as 070 first proposed. It covers only
the results the suite produces.

**Typed field values without a ppx**, each field declared once as a value
carrying its name, type and encoder. That catches a misspelled field but not a
field sent by a tool whose schema lacks it.

## Decided so far

With the user, September 2026.

**Scope: arguments, result and annotations.** Input schema and argument
decoding, output schema and encoding, and the tool annotations. camlkit sends
no annotations today.

**A variant is a tagged `oneOf`.** Each constructor is an object whose tag field
holds a const, `status` for `eval`, and the schema is a `oneOf` of them with
each constructor's own `required`. A flat union of every constructor's fields
was rejected because it loses which field goes with which status, which is 070
again. The wire format is unchanged: `eval` already sends `status`.

**Empty is absent by default.** `None`, `[]` and `""` are left out unless the
field says `[@keep_empty]`. That is the existing convention (ticket 004) made
the default; `context`'s `opens: []`, an answer rather than nothing, is the one
known opt-out.

**`content` is the serialized `structuredContent`, always.** The spec says a
tool returning structured content SHOULD also return the serialized JSON in a
text block. Weighed against keeping written text:

- Serialized JSON meets both the MUST and the SHOULD, with no deviation to
  justify.
- The written text adds no information. `eval`'s transcript is its
  `rendering`, `output` and `warnings` concatenated, and `context`'s `open X;;`
  lines are its `opens`. Ticket 004 already holds that structure restating text
  is not worth its bytes; this is the same rule read the other way.
- Claude Code handed the model `structuredContent` for an `eval` call in this
  session, not the transcript, so the written text was not reaching the model
  there.
- It deletes code: `Render.transcript`, the `diagnostics` summary and the
  source-query summaries, and there is no per-tool text function to keep in
  step.

Rejected: a per-tool `~text` override, which is permitted but is a deviation
each tool would have to justify; and two text blocks annotated for
`audience`, which pays every answer twice to serve a human display nobody asked
for. The cost accepted is that a client showing `content` to a person shows
JSON.

This supersedes the transcript half of ticket 004 and the "answer is code"
text of ticket 036 once built. It also removes a defect found while deciding:
the transcript glues a phrase's output to the next rendering, so
`print_string "hi"; x + 1;;` reads `hival _0 : int = 43`. That is not fixed
separately, since the transcript goes.

**`Tool.make` owns server failure.** A handler returns
`(result, failure) Stdlib.result`. `failure` is one shared derived type tagged
`status: "error"`, carrying `message` and, since 063, `exit_code` or `signal`.
`Tool.make` adds it as a `oneOf` branch to every tool's output schema and sets
`isError` for it, so no tool can forget either. A negative answer to a fine
question, such as `describe`'s `Unknown`, stays a constructor of the result
type and is not `isError`, as 002 and MAP's consistency note hold. Rejected: a
failure constructor in each of nineteen result types, which each tool repeats
and can omit; and an `isError` result with text only, which drops the fields
063 just added and leaves a declared schema unconformed.

## Open

**How `eval` answers later.** Its result arrives from the worker after the call
returns, through `pending`; the typed reply has to survive that.

**Where the manual goes.** `[@doc]` gives descriptions per field; ticket 062
keeps a tool's description short and its manual behind `help`.
