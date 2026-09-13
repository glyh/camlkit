---
status: closed
type: decision
assignee: lyh
---

# Descriptions are triggers, the manual is help

## Problem

A tool's description and input schema are loaded into an agent's context with
the tool, whether or not it is then called. They had grown into the manual:
eval's description listed every swap restriction, its `cost` argument explained
the measurement floor with a worked number, and the output schemas described
every field. Measured over `tools/list`: 16.4 KB of description and input
schema across eighteen tools, 30.5 KB with output schemas.

The detail was not wrong. It was paid for on every load instead of when a call
needed it, and most of it restated what a result or an error already says: a
swap that cannot happen names why in its error.

## Decision

A description is a trigger: when to reach for the tool, and the one mistake
that would make a call wrong (every phrase must typecheck, qualify type names,
the position goes on the deriver). Argument and output-field descriptions are a
clause or absent.

Everything else lives in `lib/guide.ml`, served by a nineteenth tool, `help`,
which takes a tool name. Every other description ends `Manual: help <name>.`,
because a client that loads tools on demand may have loaded only that one, and
has to learn from it that a manual exists. A test fails when a listed tool has
no manual.

After: 7.2 KB of description and input schema, 12.3 KB with output schemas.

## Rejected

- **MCP resources.** The protocol's own place for documents, but client support
  is uneven and an agent has to know to look. A tool is reachable from every
  client the other eighteen are.
- **Pointing at the README.** An installed server has no repository, and an
  agent cannot be sure where one is.
- **Trimming without moving.** Loses what an agent debugging an edge case needs.
