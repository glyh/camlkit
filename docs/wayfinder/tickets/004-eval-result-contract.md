---
status: open
type: grilling
blocked-by: [003]
assignee:
---

# What an eval returns to the agent

## Question

utop reports parse verdict and error spans on `accept:`, but sends
warnings, type errors and runtime exception traces all on `stderr:`,
while values land on `stdout:`. An agent consuming this needs to tell a
compile error from a warning from a runtime failure, because the next
action differs in each case.

Decide the result structure the eval tool returns, how error locations
map back onto the submitted source, and whether a failed phrase is an MCP
tool error or a successful call carrying a failure payload.

Needs real captures from the session driver to decide against, not
guesses.
