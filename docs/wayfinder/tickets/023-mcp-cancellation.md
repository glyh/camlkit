---
status: closed
type: prototype
blocked-by: []
assignee: lyh
---

# Honour a cancellation notification

## Question

MCP defines a cancellation notification for an in-flight request. We ignore
every notification, so a client that gives up on a slow evaluation is still
charged the full deadline, and the worker keeps running.

The machinery is already here, which is why this is a prototype rather than
a question: `Supervision` has an interrupt-then-kill escalation and the
server tracks one pending request per session. Cancelling is the same
escalation triggered by a message instead of by a clock.

Decide what the cancelled request returns, if anything, and whether the
session survives - an interrupt leaves it usable, so it should.

Noted as missing in [ocaml-mcp](https://github.com/tmattio/ocaml-mcp) too,
where it is called out as needing thread-safe cancellation tokens. Our
select loop needs no tokens: the signal goes to a different process.

## Resolution

`notifications/cancelled` is honoured. Its params carry a `requestId` and an
optional `reason`.

**The interrupt is the right first move**, not a kill: it leaves the toplevel
usable, and the deadline already in flight escalates to a kill if the worker
ignores it. So cancelling a runaway phrase costs the phrase, not the session.
Tested: a cancelled session evaluates normally afterwards.

**No response is sent for a cancelled request**, which the spec requires. The
worker still owes us an answer, though, and an unread frame would wedge the
session, so the answer is read and discarded rather than ignored. That
distinction is the whole of the implementation's subtlety.

**The race is handled by design rather than by guarding.** A cancellation for
a request that already finished finds nothing pending and is ignored, as is
one for an id that never existed. Both are tested, because the spec calls out
that they will happen and must not disturb anything.

**Ids are matched exactly, with no coercion.** JSON-RPC 2.0 says an id "MUST
contain a String, Number, or NULL value if included", and the MCP
cancellation page's own example uses `"requestId": "123"`, so both forms are
conforming and neither is refused. What is refused is a cancellation whose id
matches only after coercing a number to its decimal spelling: a client knows
what it issued, so that is a client bug, and obliging it silently would hide
it. The request keeps running and the session stays busy, which is tested.

**The failure names what it could have meant.** Every pending id is held
here, so the candidates are known rather than guessed:

```
ignoring notifications/cancelled for "7": no request was issued with that
id. Pending: session "s" is waiting on 7 (number)
  it differs only in JSON type from the id session "s" is waiting on. Cancel
  with the id exactly as it was issued; a number and its decimal spelling are
  different ids.
```

A cancellation arriving when nothing is pending stays silent: that is the
race the spec says to expect. The distinguishing question is whether any
request was in flight at all, not whether the id was recognised.

Nothing needed thread-safe cancellation tokens, which
[ocaml-mcp](https://github.com/tmattio/ocaml-mcp) lists as the reason it has
not done this. The signal crosses a process boundary, so the worker being
mid-computation is not an obstacle; it is the mechanism.
