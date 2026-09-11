---
name: watch-and-fix
description: Watch one GitHub pull request and run a pr-fix cycle whenever it owes work, until it is all green, the user stops, or it closes. Never merges. Use to babysit a PR through review. For a single fix cycle, use pr-fix instead.
---

# Watch and Fix

Keep one pull request moving through review as the **Developer**. This skill is a **loop and nothing
else**: it holds the poller and the Developer's target lock, and every time the pull request changes in
a way that owes work it runs one **pr-fix** cycle. It validates nothing itself, edits no code, pushes
nothing, and replies to no one — every change this run causes is made by the pr-fix cycle it started,
under that skill's own rules, worktree, and identity.

That separation is the point. Fixing is one bounded job that ends with a push and a report; watching is
a different job that decides when to do the first one again. Keeping them apart means a fix always
answers the feedback that was open when it started, and the loop can be read in a page.

At the start of every run, read `references/policy/trust.md`, `references/policy/identity.md`,
`references/policy/polling.md`, `references/policy/worktrees.md`, `references/policy/conventions.md`,
and `references/policy/handoff.md`. Read the installed **pr-fix** package before the first cycle: its
`SKILL.md` is the specification for everything this loop causes to happen.

## Boundaries

- **One pull request.** Resolve the URL once and restrict every read and snapshot to it.
- **Title the session.** When the runtime lets the session be titled, title it
  `watch and fix [#<pr number>]` as soon as the target is known, applying the session-title
  capability per `references/policy/handoff.md`.
- **Start pr-fix from its installed package**, never from memory, per the contract in
  `references/policy/handoff.md`.
- **Arm before you cycle.** A live wake source is a precondition of every cycle, including the first.
  Waiting is not a state this skill can be in without one.
- **One cycle at a time, and wait for it.** Never start a second cycle while one is running. A snapshot
  that lands mid-cycle is folded into the decision made when that cycle returns.
- **This skill writes nothing** — no commit, no push, no comment, no lifecycle change. If it seems
  necessary to change something, that belongs in the cycle, not the loop.
- **Never merge**, and never resolve a review thread. Neither does the cycle it starts.

## Identity and the lock

Select a `read`-capable account with `scripts/gh_identity.sh select --need read`, per
`references/policy/identity.md`. The loop only reads; the cycle selects the `comment`- and
`push`-capable account its own work requires and discloses that login itself.

Take the Developer's target lock once with `scripts/run_lock.sh acquire`, register the run, and **pass
this run's identifier into every cycle** so it resumes that lease through `run_lock.sh resume` instead
of acquiring a second Developer lock on the same pull request. The worktree the first cycle creates
persists between cycles under pr-fix's own rules — that is why the lease is passed rather than the lock
retaken, and why a later cycle starts from an existing checkout instead of rebuilding the most expensive
thing this pair of skills does.

A Developer run already registered for this pull request, still `active`, whose lease heartbeat has
expired, is this role's own dropped loop rather than a competitor. Adopt it: take over that run
identifier, read the last processed cursor and fingerprint from the watcher state file, re-arm the wake
source, and continue from there — the retained worktree is the whole reason not to start over. Say in
the first status line that a dropped loop was adopted, with the cycle it left off at.

## The loop

**Arm the wake source first.** Nothing else in this skill runs until one of the two modes in
`references/policy/polling.md` is live, because the wake source — not this turn — is what carries the
loop from one cycle to the next. A cycle ends its turn with its report; a loop that lives only in that
turn ends with it, after one fix, looking exactly like a loop waiting quietly.

1. Establish the mode the runtime actually supports, before the first cycle:

   - **Attached.** Hold

     ```text
     scripts/poll_pr.sh --watch --interval 120 --cursor <last processed cursor> \
       --if-changed-since <last processed fingerprint> <target>
     ```

     as a live change-filtered event source and wait on its output.
   - **Wake-up.** When the runtime cannot hold a blocking process attached — or refuses `--watch` —
     create its own recurring event source, per `references/policy/handoff.md`, running

     ```text
     scripts/poll_pr.sh --once --cursor <last processed cursor> \
       --if-changed-since <last processed fingerprint> <target>
     ```

     every 120 seconds and delivering each changed snapshot. Exit **3** is an unchanged capture and ends
     that wake-up after the single script call. Resume the same run identifier, cursor, and fingerprint
     through `scripts/run_lock.sh resume`.

   Never schedule unconditional cadence-based agent turns in either mode. Confirm the source is live,
   then print one line naming the mode, the target, and when the next capture falls. If neither mode can
   be established, say so and stop — never run one cycle and end as though still watching.
2. On each changed snapshot, decide whether the pull request **owes work**: a new or updated review, a
   substantive comment or question, a failing required check, a base that has moved, or a terminal
   Manual QA `FAIL`. When it does, run **one pr-fix cycle**, handing it the target, this run's
   identifier, the previous cursor and fingerprint, and the decisions the user gave at invocation.
3. When the snapshot owes nothing — an acknowledgement, a reaction, a change that touches nothing this
   skill answers — run no cycle and print nothing.
4. Read the cycle's report, record its run identifier, cursor, and fingerprint, print one line for the
   user naming what it pushed and answered, and go back to waiting on the armed source.
5. Stop when a stop condition below is observable.

**Only a changed pull request costs a cycle.** No output is a wait state, not completion, and never
requires the user to re-invoke. Never post heartbeat comments — this skill posts nothing at all.

A cycle can also spend time queued: heavy work — full suites, builds, dependency installs — shares a
machine-wide limit of **two concurrent heavy tasks**, taken through
`scripts/run_lock.sh sem-acquire heavy local`. A cycle reporting that it is waiting for a heavy-task
slot is queued behind other runs, not stalled; let it wait.

That holds only while the wake source is armed. Silence from an unarmed loop is not patience, it is a
finished run that never said so — which is why the mode is confirmed and named before the first cycle.

## What a cycle is told

- the pull-request URL;
- this run's identifier, previous cursor, and previous fingerprint, so it resumes its lock and worktree
  rather than building new ones;
- the human reviewer to request on a ready revision;
- the browser authorization or waiver, and the Manual QA decision, when the user gave them;
- that it is running under a parent: defer a decision the user must make through its own blocker path
  rather than guessing, and end its turn with its report.

A decision that arrives mid-run goes into the next cycle's brief. Never post it to the pull request
expecting the cycle to obey it.

## Stopping

The pr-fix cycle recomputes **all green** itself and reports it; this loop never computes it and never
overrides it. Stop when a cycle reports all green on the live tuple, when the user asks to stop, or when
the pull request closes or merges.

**A pull request that is not all green is not a reason to stop, and neither is quiet.** All green
requires every reviewer thread to be resolved, and neither this skill nor pr-fix may resolve one — on a
pull request reviewed by humans, the last condition closes only when a person acts. So when every
substantive comment has its reply, the branch is synchronized, required checks are green, and only
human-held threads remain, keep the armed wake source live **without counting quiet captures**.
Do not wake the agent or emit status merely to prove that nothing changed. The reviewer who returns in
an hour finds this loop still listening, and the hour cost nothing. This is not all green and must never
be reported as such.

A required Manual QA run that is planned, running, blocked, stale, or waiting for a rerun is **not** a
human-held quiet boundary. It is outstanding work: keep watching, so a failure reaches a cycle and a
terminal result reaches the Reviewer.

On stopping, let the live cycle finish if there is one, then release the target lock, finalize the
registry entry, and report: the pull request's state and the lifecycle readback the last cycle returned,
what the cycles pushed and answered, how many ran, and anything retained with its path. A worktree
holding unpushed work is retained, not removed, and said so. Never remove a cycle's worktree; only the
skill that created it may.

Do not watch later commits after stopping; require a new invocation. Several Watch and Fix runs may
watch different pull requests at once; each cleans up only its own.
