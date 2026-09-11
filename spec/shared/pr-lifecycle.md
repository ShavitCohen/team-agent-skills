# PR lifecycle and ticket ownership

*Part of the Team Agent Skills specification — split from the master document.*

## GitHub PR and board lifecycle

Shipped as `references/policy/pr-lifecycle.md` by Implement, PR Fix, and PR Review.
It enforces the team's PR and board lifecycle whenever a skill creates, updates, reviews, or
reports on a pull request and its linked project ticket. Maintain this invariant:

> Every open PR is either Draft, or Ready for review with a human reviewer requested or a
> completed human decision for the current review round.

**Opening a PR.** Create the PR as Draft when work, validation, or self-review remains. Keep its
linked ticket In Progress. Link the correct project ticket. If no human reviewer can be named, keep
the PR Draft.

**Requesting review.** Before marking a PR ready: confirm the implementation is complete; run the
relevant tests and checks; self-review the complete diff; update the PR description and evidence;
mark the PR Ready for review; request a named human reviewer immediately; move the linked ticket to
Waiting for PR Approval. Treat marking Ready and requesting the reviewer as **one operation**.

**Responding to review.** After Changes Requested, move the ticket to In Progress. Address the
findings and rerun validation. Re-request the reviewer when the new revision is ready. A bot
review, author review, or comment-only review does not replace the required human decision.

**Completion.** Merge only after the required human approval and required checks. Close the ticket
or move it to Done after delivery to the authoritative default branch.

**Guardrails.** Never use Blocked merely because review has not been requested. Never change board
status only to silence a hygiene finding. Convert a Ready PR back to Draft when author work
remains. Close or supersede obsolete and duplicate PRs. Treat an approval that predates a retarget
of the PR's base branch as stale for the current round — GitHub does not dismiss it, so the round's
human decision must postdate the current base. Before finishing, verify the PR draft
state, requested reviewers, review decision, linked ticket, and board status.

**How the family applies it.** Board status moves through the project-board mechanism only —
ticket bodies, titles, labels, milestones, and assignees stay untouched per
[Ticket ownership](#ticket-ownership--never-edit-a-ticket-body). "Merge only after…" binds the
human who merges; no skill merges, and the Reviewer's automated approval never substitutes for the
required human decision. Closing an obsolete or duplicate PR is a recommendation to its owner, not
an action a watcher skill takes. Implement opens Draft while anything remains and, once converged
and self-reviewed, marks Ready plus requests the named human reviewer as one operation; Watch and
Fix keeps the invariant through review rounds (In Progress on Changes Requested, Draft when author
work remains, re-request on the ready revision); PR Review verifies the invariant and
publishes violations as hygiene findings without changing those states itself.

## Ticket ownership — never edit a ticket body

No skill in this family changes the body of a ticket. The issue body, title, labels, milestone, and
assignees belong to whoever wrote them, and a ticket that an agent has quietly rewritten is no longer
usable as evidence of what was asked. Everything a skill contributes to a ticket — a clarity summary,
resolved clarifications, progress, a blocker, even a correction to the ticket's own text — is posted
as an **issue comment**.

This is absolute:

- Never call `gh issue edit`, and never reach the same effect through `gh api`. Editing a title,
  swapping a label, or reassigning is the same violation as rewriting the body.
- It is not a fallback. When a comment cannot be posted, stop and report the missing capability; do
  not write into the body instead.
- It does not yield to obviousness. A ticket that is stale, wrong, or self-contradictory gets a
  comment saying so, plus a line in the final report, and a human makes the edit.
- It does not yield to a direct request either. If the user asks a skill to edit the body, say the
  skill does not edit ticket bodies and leave the edit to them.
- A pull request the family **authors** is a different artifact: writing and updating that PR's own
  body and description is in bounds for the skill that owns it.

Because updates are comments, they are append-only and ordered, which removes the machinery a body
edit needed: no clarity-section boundary parsing, no body fingerprint, no conditional update, no
cross-skill issue-body lock. What replaces it is **idempotency** — every posted comment carries the
skill's automation marker, and every skill re-reads the comment list and looks for its own marker
before posting, so a retried run replies once instead of twice.
