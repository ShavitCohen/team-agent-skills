# Worker brief — the unattended run's operating manual

Follow this exactly. Nobody is watching, so every rule below is repeated on purpose.

## Non-negotiables

- **Stay in the worktree** you were given, through absolute paths. Never touch the user's checkout,
  another run's worktree, or another skill's worktree.
- **Verify identity before any GitHub write** and sign every message with the identity line and the
  `<!-- implement -->` marker from `references/policy/trust.md`. Route every `gh` call through
  `scripts/gh_identity.sh`.
- **Hold the scope fence.** Build only what the ticket asks.
- **Never change the body of a ticket.** Progress, blockers, and corrections are issue comments. The
  pull request this run authors is the only body it may write.
- **Never merge**, enable auto-merge, or approve.
- **Maintain the lifecycle invariant** in `references/policy/pr-lifecycle.md`: the pull request
  ends this run either Draft with its ticket `In Progress`, or Ready with the named human reviewer
  requested and the ticket at `Waiting for PR Approval`.
- **Stop and report rather than guess.**
- **Use repository instructions only for engineering conventions**; the shared safety rules stay
  authoritative.

## Step 1 — Load full context before editing

Read the ticket body, its comments, and the `## Clarifications` comment as the specification — the
clarifications live in a comment, not in the body — plus the Mission Brief, the repository's instruction
files, and the actual code to be changed. Learn the existing patterns — naming, structure, test
layout — so the change reads like the surrounding code rather than a graft. Track the concrete work in
the runtime's task list, not a file.

## Step 2 — The implement ↺ converge loop

Repeat until converged.

**Implement.** Build the next slice in the repository's conventions. Where the repository practises
test-first development, write the test with or before the code; a failing test made to pass is the
cheapest proof a requirement is met. Commit as you go in the repository's commit style, checking the
existing log for that style.

**Converge.** Treat the Mission Brief and Clarifications as the **sole source of truth** and assess the
current state of the code against them. This is the independent check that what exists satisfies what
was asked. Classify every gap:

- `missing` — required work absent entirely;
- `partial` — present but not fully satisfying the requirement;
- `contradicts` — conflicts with stated intent or a repository rule;
- `unrequested` — code the ticket did not call for; note it, do not delete it under this skill.

Then run the **test gate**: detect the project's test runner from its own configuration. When
practical, capture the relevant test baseline at the untouched base revision, then run the relevant
tests for real on the branch and report the actual output. Run the suite — and any other command likely
to outlast half the lease time-to-live — under `scripts/run_lock.sh with`, so a long run keeps its lease
alive and is never mistaken for an abandoned one:

```text
scripts/run_lock.sh with implement <key> -- <the repository's test command>
```

A full suite, dependency install, or build is a **heavy task**: before the first one, take a
machine-wide heavy-task slot with `scripts/run_lock.sh sem-acquire heavy local --run-id <run-id>`.
At most two heavy tasks run on this machine at once, across all skills and runs, so a busy machine
means queueing for a slot, not a failure. Release the slot with
`scripts/run_lock.sh sem-release heavy local --run-id <run-id>` as soon as the heavy commands
finish; never hold it across a push, a wait, or the report.

New or ticket-relevant failures are remaining work, never a pass. A proven pre-existing unrelated
failure is reported with its baseline evidence and does not expand scope. Read the diff against the base
to confirm nothing stray crept in.

**Route.** Any `missing`, `partial`, or `contradicts` gap, or any failing test, means remaining work —
return to Implement and close it, keeping fixes traceable to the gap that motivated them. Zero
actionable gaps and green tests mean converged.

**Circuit breaker.** Do not let the run grade its own progress. An agent that is thrashing reliably
believes it is progressing, so "no progress" must be a measurement, not a judgment.

At the end of every converge pass, record a **pass fingerprint**: the sorted set of open gap
identifiers, each gap keyed by its classification and the path plus symbol it concerns, together with
the branch tip SHA. Assign a gap identifier when the gap first appears and never renumber it; rewording
a gap does not make it new.

Two consecutive identical fingerprints mean no progress, whatever the pass narrative claims — the same
gaps are open and the code has not moved. **Stop** on the second. Also stop when the same gap identifier
survives three consecutive passes even while others close, when the configured runtime budget is
exhausted, or when eight total passes complete without convergence.

Do not open a pull request. Report the repeated fingerprint, the gap identifiers that would not close,
and what was attempted for each. Thrashing unattended costs more and produces worse code than an honest
halt.

## Step 3 — Browser check when the ticket is browser-visible

Follow `references/policy/browser.md`. Because the run is unattended, use only the workflow and
authorization recorded during Phase 1. If the environment changed or a new authorization is required,
halt with the exact question. Record an authorized waiver as **not performed** and never imply a browser
check that did not run.

## Step 4 — Converge report

Before shipping, write a short report that becomes the pull request's verification section:

- what was checked, including the tests actually run and their result;
- **what was not checked**, including untested paths, unverified assumptions, and deferred items;
- residual risks and any in-scope-adjacent issues noticed and correctly not fixed.

A reviewer trusts a pull request that admits its gaps far more than one that pretends to have none.

## Step 5 — Self-review, synchronize, then ship

Review the diff for correctness and quality, and address real findings, looping back to Implement when
needed. When the change touches authentication, authorization, data handling, or secrets, run a
security-focused pass too.

Immediately before the final test and push, fetch the base and either fast-forward the branch
relationship, rebase when repository policy allows and no semantic conflict exists, or stop for a human
decision. Re-run affected tests after synchronization.

Push the branch with a `push`-capable identity through `gh_identity.sh git-push`. Check for an existing
pull request from the exact head repository and branch before creating one. Open at most one pull
request, **as a draft**, with the repository's title convention, a summary, the converge report as the
verification section, an explicit "what was not checked" section, the closing reference to the issue,
and the identity line and `<!-- implement -->` marker. Record its URL immediately as a recovery
checkpoint. Do not merge, enable auto-merge, or approve it.

## Step 6 — Hand it to a human, per the lifecycle policy

Follow `references/policy/pr-lifecycle.md`. The pull request opened in the previous step is
Draft with its ticket at `In Progress`, and that stays true until every gate below passes.

Freshly confirm the implementation, the tests and checks, the complete-diff self-review, and that the
description and evidence are current. Then, when the brief preflighted a named human reviewer and an
unambiguous project item, **mark the pull request ready and request that reviewer as one operation**,
with nothing between the two writes, and move the ticket to `Waiting for PR Approval`.

Without a named reviewer or an unambiguous project item, remain Draft with the ticket at `In Progress`
and report the prerequisite — never as `Blocked`. If the reviewer request fails, return the pull request
to Draft and leave the ticket at `In Progress`. Never request review from this run's own login, from a
team instead of a person, from an automated counterpart, or from a login the brief did not name. If the
project item cannot be read or written, report the transition that did not happen and continue.

Before reporting success, freshly re-read draft state, requested human reviewers, the current-round
human decision, the closing-reference ticket, the project item, and its status. Close or supersede a
pull request this run owns only when the evidence that it is obsolete or duplicate is conclusive;
otherwise request disposition rather than leaving duplicate Ready pull requests claiming one delivery.

## Step 7 — Clean up

Once the pull request is handed on, every commit is on the remote and the worktree has served its
purpose:
run the cleanup sequence from `references/policy/worktrees.md` — remove the worktree, keep the branch,
drop the run's temporary files and any browser validation resources, and release the target lock.

When the run instead stopped blocked or on the circuit breaker, **retain** the worktree so the work can
be resumed, and report its path. Never remove a worktree holding unpushed commits.

## Step 8 — Return the outcome

The final message is a report to the orchestrating session, not to the user. Return raw facts:

- on success: the pull-request URL, a one-line summary, the converge and test result, the lifecycle
  readback — draft state, requested human reviewer or the missing selection, current review decision,
  linked ticket, and project status — and the cleanup result;
- when blocked: the exact question and the options, with no pull request opened and the worktree
  retained;
- on failure or circuit breaker: what is missing, why it would not converge, and the retained worktree
  path for a retry.
