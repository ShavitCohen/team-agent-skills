# Watch and Fix

## Package

Create this portable package with the same file list as [Watch and Review](watch-and-review.md), and
the same three deliberate absences — no `gh-commands.md`, no `browser.md`, no `pr-lifecycle.md` —
because this skill likewise edits nothing, pushes nothing, and writes no lifecycle state. Everything
it causes to happen is done by the [PR Fix](pr-fix.md) cycle it starts.

Use this frontmatter:

```yaml
---
name: watch-and-fix
description: Watch one GitHub pull request and run a pr-fix cycle whenever it owes work, until it is all green, the user stops, or it closes. Never merges. Use to babysit a PR through review. For a single fix cycle, use pr-fix instead.
---
```

## Purpose

Keep one pull request moving through review as the **Developer**. This skill is a **loop and nothing
else**: it holds the poller and the Developer's target lock, and every time the pull request changes
in a way that owes work it runs one PR Fix cycle. It validates nothing itself, edits no code, pushes
nothing, and replies to no one.

## Identity and the lock

Select a `read`-capable account; the cycle selects and discloses the `comment`- and `push`-capable
account its own work requires.

Take the Developer's target lock once and **pass this run's identifier into every cycle**. The
worktree the first cycle creates persists between cycles under PR Fix's own rules — that is why the
lease is passed rather than the lock retaken, and why a later cycle starts from an existing checkout
instead of rebuilding the most expensive thing this pair of skills does.

A Developer run already registered for this pull request, still `active`, whose lease heartbeat has
expired, is this role's own dropped loop rather than a competitor. Adopt it — run identifier, cursor,
fingerprint, and retained worktree — re-arm the wake source, and continue; that retained worktree is
the whole reason not to start over. Say in the first status line that a dropped loop was adopted.

## The loop

**Arm the wake source first**, on the same terms as [Watch and Review](watch-and-review.md): the wake
source, not the current turn, is what carries the loop from one cycle to the next.

1. Establish the mode the runtime actually supports, before the first cycle: hold
   `poll_pr.sh --watch --interval 120` attached as a live change-filtered event source, or — when the
   runtime cannot hold a blocking process attached, or refuses `--watch` — create its own recurring
   event source, per `references/policy/handoff.md`, driving `--once --if-changed-since` at the same
   cadence. Confirm it is live, name the mode and the next capture, and stop rather than cycle if
   neither mode can be established.
2. On each changed snapshot, decide whether the pull request **owes work**: a new or updated review, a
   substantive comment or question, a failing required check, a base that has moved, or a terminal
   Manual QA `FAIL`. When it does, run **one PR Fix cycle** with the target, this run's identifier,
   the previous cursor and fingerprint, and the decisions the user gave at invocation.
3. When the snapshot owes nothing — an acknowledgement, a reaction, a change that touches nothing this
   skill answers — run no cycle and print nothing.
4. Read the cycle's report, record its continuation values, print one line naming what it pushed and
   answered, and go back to waiting on the armed source.

## Stopping

The PR Fix cycle recomputes **all green** itself and reports it; this loop never computes it and never
overrides it. Stop when a cycle reports all green on the live tuple, when the user asks to stop, or
when the pull request closes or merges.

**A pull request that is not all green is not a reason to stop, and neither is quiet.** All green
requires every reviewer thread to be resolved, and neither this skill nor PR Fix may resolve one — on
a pull request reviewed by humans, the last condition closes only when a person acts. So when every
substantive comment has its reply, the branch is synchronized, required checks are green, and only
human-held threads remain, keep the armed wake source live **without counting quiet captures**. Do not
wake the agent or emit status merely to prove that nothing changed. The reviewer who returns in an hour
finds this loop still listening — because the source is armed, not because the turn is still open — and
the hour cost nothing. This is not all green and must never be reported as such.

A required Manual QA run that is planned, running, blocked, stale, or waiting for a rerun is **not** a
human-held quiet boundary. It is outstanding work: keep watching, so a failure reaches a cycle and a
terminal result reaches the Reviewer.

On stopping, let the live cycle finish, release the target lock, and report the pull request's state
and lifecycle readback, what the cycles pushed and answered, how many ran, and anything retained with
its path. A worktree holding unpushed work is retained, not removed, and said so.

## Validation

- confirm the package contains no commit, push, comment, thread-resolution, merge, or lifecycle
  invocation of any kind, and ships none of the fix policy;
- confirm every change in a run was made by the PR Fix cycle, under that skill's identity and
  worktree;
- confirm a snapshot that owes no work starts no cycle and prints nothing;
- confirm no cycle can start before a wake source is armed, that the mode in use is named to the user,
  and that a run able to arm neither mode stops and says so instead of performing one cycle;
- confirm a registered run of the same role and target with an expired lease is adopted as a dropped
  loop, keeping its run identifier, continuation values, and retained worktree;
- confirm the loop takes the target lock once and every cycle resumes that lease, so the worktree
  persists across cycles rather than being rebuilt;
- confirm quiet is never reported as all green, and human-held threads keep the loop dormant rather
  than stopping it;
- confirm a pending Manual QA state keeps the loop watching;
- confirm stopping never removes a cycle's worktree, and unpushed work is retained and reported;
- confirm no hardcoded vendor, model, person, account, repository, or installation path exists.
