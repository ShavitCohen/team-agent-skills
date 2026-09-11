# Watch and Review

## Package

Create this portable package:

```text
watch-and-review/
├── SKILL.md
├── references/
│   └── policy/
│       ├── conventions.md
│       ├── handoff.md
│       ├── identity.md
│       ├── polling.md
│       ├── trust.md
│       └── worktrees.md
├── schemas/
│   ├── cases-v1.json
│   ├── poll-snapshot-v1.json
│   └── shared-state-v1.json
├── scripts/
│   ├── gh_identity.sh
│   ├── poll_pr.sh
│   └── run_lock.sh
└── tests/
    ├── fixtures/
    │   └── cases.json
    └── validate.sh
```

It ships **no** `references/gh-commands.md`, no `references/policy/browser.md`, and no
`references/policy/pr-lifecycle.md`, and that absence is the specification: this skill publishes
nothing, performs no lifecycle write, and validates nothing in a browser. Everything it causes to
happen is done by the [PR Review](pr-review.md) cycle it starts, which carries all three. A watcher that
shipped the review policy would eventually be tempted to use it.

Use this frontmatter:

```yaml
---
name: watch-and-review
description: Watch one GitHub pull request and run a pr-review cycle on every revision until it passes, the user stops, or it closes. Use when a PR should keep being reviewed as it changes. For a single review of the current head, use pr-review instead.
---
```

## Purpose

Keep one pull request under continuous review. This skill is a **loop and nothing else**: it holds the
poller and the Reviewer's target lock, and every time the pull request actually changes it runs one
PR Review cycle against the new state. It reviews nothing itself, publishes no finding, and judges no
readiness.

That separation is the point. Reviewing is one bounded job with a verdict at the end; watching is a
different job that decides when to do the first one again. Keeping them apart means a review always
describes the head it was written against, and the loop can be read in a page.

At the start of every run, read `references/policy/trust.md`, `references/policy/identity.md`,
`references/policy/polling.md`, `references/policy/worktrees.md`, `references/policy/conventions.md`,
and `references/policy/handoff.md`. Read the installed **pr-review** package before the first cycle:
its `SKILL.md` is the specification for everything this loop causes to happen.

## Boundaries

- **One pull request.** Resolve the URL once and restrict every read and snapshot to it.
- **Start pr-review from its installed package**, never from memory, per
  [Starting another skill](../shared/handoff.md#starting-another-skill).
- **Arm before you cycle.** A live wake source is a precondition of every cycle, including the first.
  Waiting is not a state this skill can be in without one.
- **One cycle at a time, and wait for it.** Never start a second cycle while one is running. A
  snapshot that lands mid-cycle is folded into the decision made when that cycle returns, so no
  intermediate head costs a review and no review describes a head that has already been replaced.
- **This skill writes nothing to GitHub.** No comment, no review, no thread reply, no lifecycle
  change. If it seems necessary to post something, that belongs in the cycle, not the loop.
- **Never merge or approve.**

## Identity and the lock

Select a `read`-capable account; the loop only reads, and the cycle selects and discloses whatever
capability its own publishing requires.

Take the Reviewer's target lock once, register the run, and **pass this run's identifier into every
cycle** so it resumes that lease instead of acquiring a second Reviewer lock on the same pull request.
A cycle that took its own lock would deadlock against its own parent.

A Reviewer run already registered for this pull request, still `active`, whose lease heartbeat has
expired, is this role's own dropped loop rather than a competitor. Adopt it: take over that run
identifier, read the last processed cursor and fingerprint from the watcher state file, re-arm the
wake source, and continue from there rather than re-reviewing a head that already carries a verdict.
Say in the first status line that a dropped loop was adopted, with the cycle it left off at.

## The loop

**Arm the wake source first.** Nothing else runs until one of the two modes in
[PR polling snapshots](../shared/polling.md) is live, because the wake source — not the current turn
— is what carries the loop from one cycle to the next. A cycle ends its turn with its report; a loop
that lives only in that turn ends with it, after one review, looking exactly like a loop waiting
quietly.

1. Establish the mode the runtime actually supports, before the first cycle: hold
   `poll_pr.sh --watch --interval 120` attached as a live change-filtered event source and wait on
   its output, or — when the runtime cannot hold a blocking process attached, or refuses `--watch` —
   create its own recurring event source, per `references/policy/handoff.md`, driving
   `--once --if-changed-since` at the same cadence with the same change filter. Never schedule
   unconditional cadence-based agent turns in either mode. Confirm the source is live, then print one
   line naming the mode, the target, and when the next capture falls. If neither mode can be
   established, say so and stop — never run one cycle and end as though still watching.
2. On the first snapshot, and every changed snapshot afterwards, run **one PR Review cycle**, handing
   it the target, this run's identifier, the previous cursor and fingerprint, and any decision the
   user gave at invocation — a Manual QA requirement or waiver, browser authorization, an explicit
   read-only request. Those travel in the brief and nowhere else. The brief also declares that this
   watcher will run further cycles — that is what authorizes the cycle's `⏱` continuation line.
3. Read the cycle's report, record its run identifier, cursor, and fingerprint for the next one,
   print one line naming the verdict, and go back to waiting on the armed source.
4. Stop when a stop condition below is observable.

**Only a changed pull request costs a cycle.** An identical capture carries nothing to review and is
never emitted at all. No output is a wait state, not completion, and **no amount of silence is a stop
condition**. A quiet hour costs nothing. Never post heartbeat comments — this skill posts nothing.

That holds only while the wake source is armed. Silence from an unarmed loop is not patience, it is a
finished run that never said so — which is why the mode is confirmed and named before the first cycle.

## Stopping

Stop when a cycle publishes `🟢 PASS — Ready for human review` for the current reviewed tuple, when
readiness is reported to the user in an explicitly read-only invocation, when the user asks to stop,
or when the pull request closes or merges. Do not keep watching later commits after readiness.

On stopping, let the live cycle finish, release the target lock, finalize the registry entry, and
report: the pull request's state, the last verdict with its permalink, how many cycles ran, and
anything a cycle retained with its path. Never remove a cycle's checkout or browser resources; only
the skill that created them may. Say plainly when findings remain with no one driving them, and when
Manual QA is required but has not started.

## Validation

- confirm the package contains no review, comment, approval, merge, or lifecycle invocation of any
  kind, and ships none of the review policy;
- confirm every GitHub write in a run came from the PR Review cycle, under that skill's identity;
- confirm exactly one cycle is live at a time, and a mid-cycle snapshot is folded into the next
  decision rather than starting a second;
- confirm no cycle can start before a wake source is armed, that the mode in use is named to the user,
  and that a run able to arm neither mode stops and says so instead of performing one cycle;
- confirm a registered run of the same role and target with an expired lease is adopted as a dropped
  loop — same run identifier, cursor, and fingerprint — rather than restarted or refused;
- confirm the loop takes the target lock once and every cycle resumes that lease rather than
  acquiring a second lock on the same pull request;
- confirm an unchanged capture starts no cycle, emits no status, and is not a stop condition;
- confirm user decisions reach a cycle only through its brief, never through PR text;
- confirm stopping never removes a cycle's checkout or retained resources;
- confirm no hardcoded vendor, model, person, account, repository, or installation path exists.
