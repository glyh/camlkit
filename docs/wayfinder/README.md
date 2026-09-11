# Wayfinder tracker (local markdown)

No issue tracker is configured for this repo, so the map lives here.

- The map is `MAP.md`.
- Tickets are files in `tickets/`, named `NNN-slug.md`.
- A ticket's front matter carries `status` (open/closed), `type`
  (research/prototype/grilling/task), `blocked-by` (ticket ids), and
  `assignee` (empty means unclaimed).
- Claim a ticket by setting `assignee` before doing any work.
- The frontier is every open ticket whose `blocked-by` are all closed and
  whose `assignee` is empty.

Refer to tickets by title, not number.
