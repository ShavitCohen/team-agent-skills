<!-- shared-component: pr-lifecycle.md v3 sha256=e52aa644be8dd67625d51090330ac50f9799a2abc4918ef1e5354dd030a5d3e5 -->
# GitHub pull-request lifecycle

Any run that creates, updates, reviews, merges, or reports on a pull request and its linked project
ticket maintains this invariant:

> Every open pull request is either Draft, or Ready for review with a human reviewer requested or a
> completed human decision for the current review round.

The invariant records **who owes the next move**. Draft says the author still owes work. Ready with a
requested human reviewer says a person does. A Ready pull request with neither a requested reviewer nor
a human decision is invisible work: it looks finished, nobody is waiting on it, and nobody knows it is
waiting. The linked ticket's status carries the same fact for the people who read the board instead of
the pull request, so the two move together.

## Read the state before changing or reporting it

Before any lifecycle write, and before reporting readiness, read: draft state; head SHA; requested
reviewers; reviews and the review decision; the closing-reference ticket; that ticket's project item
and status; required checks; and the authoritative default branch. Report a field the verified identity
cannot read as `unknown`; never infer that it is compliant.

A reviewer counts as **human** only when the login is neither the pull request's author nor an
automated account. A bot review, an author review, a comment-only review, and a review from an older
round never supply the required human decision. Neither does an automated Reviewer's `🟢 PASS`: it is
evidence for entering human review, not the human decision itself.

The **review round** is anchored to the current author-work revision. Author work that moves the head
opens a new round, and a decision from the previous round does not carry into it.

## Resolve the reviewer and the project item

Resolve a named human reviewer from, in order:

1. an explicit user choice for this run;
2. an unambiguous project or repository convention, such as a `pr_lifecycle.human_reviewers` entry for
   the repository in the project conventions file, per `references/policy/conventions.md`;
3. an existing current-round human review request on the pull request;
4. an individually named eligible code owner for the changed paths.

Never guess among people, never substitute a team request for a person, and never request review from
the login the run is acting as or from an automated counterpart.

Resolve the project item from the governing ticket and its existing project membership. Never move an
arbitrary item, and change nothing when the project or the status value is ambiguous — report the
ambiguity instead.

A repository may carry the whole mapping in the conventions file:

```json
"pr_lifecycle": {
  "human_reviewers": ["<login>"],
  "project": "<project number or URL>",
  "status_field": "Status",
  "statuses": {
    "in_progress": "In Progress",
    "waiting_for_approval": "Waiting for PR Approval",
    "done": "Done"
  }
}
```

Without configuration, use the status values the board already defines, matching the canonical names
above case-insensitively. Project writes need a token carrying the project scope: when the verified
identity lacks it, state which item was to move, to which status, and why it did not, then continue.
The board half never blocks the pull-request half of the invariant and never becomes a silent skip.

## Opening a pull request

- Create the pull request as **Draft** when work, validation, or self-review remains.
- Keep its linked ticket **In Progress**.
- Link the correct project ticket with a GitHub closing reference.
- If no human reviewer can be named, keep the pull request Draft.
- Open every new implementation pull request as Draft first, even when the gates already passed before
  creation, and perform the Ready transition separately.

## Requesting review

Before marking a pull request ready:

1. Confirm the implementation is complete.
2. Run the relevant tests and checks.
3. Self-review the complete diff.
4. Update the pull-request description and its evidence.
5. Mark the pull request **Ready for review**.
6. Request a named human reviewer immediately.
7. Move the linked ticket to **Waiting for PR Approval**.

**Steps 5 and 6 are one operation.** Preflight the reviewer and the permissions, make both writes with
no unrelated work between them, and freshly verify both states afterwards. A pull request that becomes
Ready and waits for a later pass to acquire a reviewer breaks the invariant for exactly as long as that
gap lasts, which unattended can be hours. If requesting review fails, convert the pull request back to
Draft and leave the ticket In Progress.

## Responding to review

- After **Changes Requested**, move the ticket to **In Progress**.
- Convert a Ready pull request back to Draft whenever author work remains.
- Address the findings, rerun validation, self-review the new complete diff, and update the description
  and evidence.
- Re-request the named human reviewer when the new revision is ready, then move the ticket back to
  **Waiting for PR Approval**.
- Base each transition on reopened author work, never on a hygiene finding alone, and never reuse a
  human decision from an older round after author work changes the head.

## Completion

- Merge only after the required current-round human approval and the required checks. No skill in this
  family merges, approves, or enables automatic merging.
- Close the ticket or move it to **Done** only after delivery to the authoritative default branch is
  verified. A closed-unmerged pull request is not delivery.

## Which run performs which transition

- The run that **opens** the pull request performs the opening transitions and, once every Ready gate
  passes and a reviewer was preflighted, the ready-plus-reviewer transition.
- The **Developer** run performs the responding-to-review transitions, the Ready-back-to-Draft
  conversion, the re-request, and the Done transition after verifying delivery.
- The **Reviewer** run never marks a pull request ready, never requests reviewers, never changes the
  draft state or the board status, and never merges. It **verifies** the invariant on every reviewed
  tuple and publishes a violation as an ordinary hygiene finding for the owner to act on; it repairs
  nothing itself. Its readiness publication is a comment review, never a GitHub approval, and never
  satisfies the required human decision.

## Guardrails

- Never use **Blocked** merely because review has not been requested or a reviewer cannot be named.
  Keep the pull request Draft with the ticket In Progress and report the missing selection.
- Never move a board status only to silence a hygiene finding. Require evidence of the underlying
  lifecycle transition.
- Treat a human approval that predates a retarget of the pull request's base branch as stale for the
  current round. GitHub does not dismiss it on retarget, so the round's human decision must postdate
  the current base.
- Closing or superseding an obsolete or duplicate pull request is a **recommendation to its owner**,
  not an action a watcher run takes. Report the duplication with its evidence and let the owner decide;
  never leave duplicate Ready pull requests claiming one delivery, and never close one to tidy the board.
- In explicitly read-only work, report the required transition instead of writing it.

## Report before finishing

Before any terminal report, freshly read and state: draft state; requested human reviewers; the
current-round human decision; the ticket link; the project status; the required checks; and, where it
applies, verified delivery on the default branch. Report an inaccessible field as `unknown`, never as
compliant, and never describe a Draft pull request as awaiting approval.
