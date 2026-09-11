# Worktrees, parallel runs, and run locks

*Part of the Team Agent Skills specification — split from the master document.*

## Parallel runs and worktree lifecycle

Assume several skills, and several runs of the same skill, are active on the same machine and often
the same repository at the same time. Every skill must be safe to run concurrently, and must leave
nothing behind when it ends.

Two rules make both true at once: **a run owns exactly one worktree**, and **the run that created a
worktree is the only thing allowed to remove it**.

### Isolation

- One run, one worktree. Never share a worktree between skills, between runs, or with the user's own
  checkout.
- Derive the worktree path from the skill, the target, and nothing that can collide:

  ```text
  <skill worktree root>/<owner>-<repository>-<issue|pr><number>
  ```

  Two skills working the same branch therefore hold two independent worktrees, and two runs on
  different tickets never meet.
- Never `checkout`, `switch`, `reset`, `clean`, `stash`, or `pull` in the main clone, in the user's
  checkout, or in any tree the run did not create. Reach into the run's own worktree by absolute path.
- Never mutate global state: no global account switch, no writes to global
  Git configuration, no changes to the user's remotes or credential helper.
- Key every scratch file, log, and temporary directory to the same run identifier as the worktree, so
  concurrent runs cannot overwrite each other's files.
- Create branches only for the run's own target, named from the ticket or PR number, so two runs
  cannot converge on one branch name.

### Managed-clone scope and registry

A managed clone is a cache and may back many worktrees for one skill. Scope its path by skill and
repository so two skills can independently check out the same branch without Git worktree branch
collisions. Concurrent `fetch` against one managed clone is safe.
`worktree add`, `worktree remove`, and `worktree prune` mutate a shared registry and are **not** —
serialize them with a process-safe lock on that clone.

Hold the clone lock only for the registry operation itself. Never hold it for the duration of the
work.

### Run registry and target locks

Record each active run in the skill's private state directory, written atomically: schema version,
skill, target, canonical worktree path, checkout mode (`editable` or `disposable-verification`),
branch or detached SHA, run identifier, start time, lease heartbeat and TTL, and state (`active`,
`retained`, `finished`).

Before starting work, take an exclusive role lock on the target — the tuple of skill, repository,
kind, and number:

- **Lock free** → take it, register the run, proceed.
- **Held by a live run** → do not start a second one. Report the existing run and its worktree, then
  stop, or continue in a read-only mode when the skill has one. Two writers on one PR produce
  conflicting pushes and duplicate comments.
- **Held by a dead run** → the lock is stale. Take it over, inspect that run's worktree, and reuse it
  rather than deleting it.

Release the lock and update the registry entry when the run ends, including on failure.

Role locks allow the intentional Developer and Reviewer pair to work on one PR. Before mutating a
resource shared across skills, also take a resource lock that omits the skill name. At minimum,
serialize managed-clone registry mutations and any single-instance local browser environment. No
skill in this family edits a ticket body, so there is no issue-body mutation to serialize: ticket
updates are comments, which GitHub already appends safely. Re-read and fingerprint mutable GitHub
content even while holding a local resource lock, because another machine may edit it.

### Cleanup

Cleanup is part of the work, not an optional extra. Run it at the end of **every** run — success,
user stop, or failure — and never let it destroy work.

1. **Determine whether removal is safe.** Apply the registered editable or
   disposable-verification rule. Never reinterpret an editable tree as disposable after work
   appears.
2. **Safe → remove.** Remove the worktree, then prune stale registrations, both under the clone lock.
   Keep the branch — it belongs to the pull request. Keep the managed clone — it is a cache.
3. **Not safe → retain.** Keep the worktree, tell the user exactly what is unsaved and where, and
   mark the registry entry `retained`. Never force removal and never delete unpushed work; a lost
   commit costs far more than a leftover directory.
4. **Remove the run's other resources**: scratch and temporary directories, and any browser
   validation resources the run created, per
   [Browser validation via an isolated local workflow](references/policy/browser.md).
5. **Release the target lock** and finalize the registry entry.

Report a one-line cleanup result: what was removed, and what was retained and why.

### Abandoned runs

At startup, each skill scans **its own** registry for entries whose lock is no longer held. For each,
report the target, worktree path, and whether it holds unsaved work, then offer to clean it up or
resume it. Never delete an abandoned worktree without asking, and never touch another skill's
registry, locks, or worktrees.

### Parallel browser validation

Concurrency reaches the cluster too. Derive the namespace and release name from the run identifier so
two runs never deploy over each other, resolve URLs and ports from the deployment output rather than
a fixed port, and delete only the namespace and resources that run created.

When the repository's local workflow supports only one shared instance, that instance is a
mutual-exclusion resource: take a lock on it, or ask the user, and never assume it is idle.

## Run locks and registry

Create `scripts/run_lock.sh` as a complete executable Bash script. It implements the mechanics of
[Parallel runs and worktree lifecycle](references/policy/worktrees.md) once, so every skill
locks, registers, and cleans up identically — and so **Clean Memory** can read the same
records to tell live work from leftovers.

It must:

- create and own a shared state layout: configuration, saved identities, locks, the run registry,
  managed clones, per-skill worktree roots, and per-run temporary directories;
- choose the state root from the environment's private skill-state mechanism or a user-approved
  project convention, create it with user-only permissions, and record its canonical path;
- acquire and release an exclusive lock per skill and target, **atomically and portably**, without
  depending on a locking utility that may be absent from the platform;
- acquire resource locks independent of skill name for shared mutations such as a managed-clone
  worktree-registry update;
- write registry entries atomically, so a concurrent reader never observes a half-written record;
- validate every JSON record against a versioned schema and preserve unknown newer versions;
- classify a lock as `free`, `live`, or `stale`;
- list runs, with liveness, for one skill or all skills;
- compute the worktree path for a target;
- report whether a worktree is safe to remove;
- remove a worktree only when it is safe, serializing registry mutation on the managed clone;
- canonicalize owner, repository, kind, number, key, and paths; reject separators, `..`, control
  characters, symlinks, and paths outside the registered root;
- accept lock and resource keys only in `[a-z0-9-]` — dashes, never slashes — and use the same
  alphabet in every example, policy file, and calling skill, so a documented key is always a valid
  key;
- refuse to remove anything not registered to the calling skill and run identifier.

**Liveness is a renewable lease, not a process.** An agent run spans many short-lived processes, so a
process identifier alone cannot say whether a run is still working. A run is live while its lease
heartbeat is within its declared time-to-live. Treat a recorded process identifier only as supporting
evidence when it names a persistent supervisor; never make a short-lived command PID a liveness
requirement. Set the default TTL comfortably above the polling interval and expected longest
non-interactive phase: default to 900 seconds and require an explicit larger TTL before a known
longer operation. Refresh before and after every pass, long test, deployment, or blocking wait.
Anything past its TTL is `stale`, but re-check the registry and worktree before takeover or reclaim.

**A pass boundary is not enough.** "Refresh before and after every pass" leaves a run silent for the
whole of a long test suite, deployment, or dependency install. A run that pushed its work just before
starting a twenty-minute suite would otherwise appear both `stale` and free of unsaved work — exactly
the profile of a reclaim candidate — while it is in fact working. Any command expected to exceed half
the TTL must therefore run under `run_lock.sh with`, which refreshes the lease on a timer for the
lifetime of the child process and stops when the child exits. Because that heartbeat child inherits
the command's file descriptors, it holds a pipe's write end open after the command exits: redirect
output inside the wrapped command, and never pipe `with` itself into a consumer that waits for
end-of-file.

Because no heartbeat is perfect, expiry alone never authorizes reclaim. A lease past its TTL makes a
run `stale`; treating it as abandoned additionally requires that nothing is unsaved **and** that no
running process holds the worktree path. See the classification rules in
**Clean Memory**.

Register each checkout as `editable` or `disposable-verification`. An editable worktree is **safe to
remove** only when it has no uncommitted or untracked changes, no commits absent from its remote
branch, and no rebase, merge, cherry-pick, or bisect in progress. A disposable verification checkout
may additionally contain artifacts proven to have been created by recorded test or build commands
after a clean baseline, but it is unsafe if tracked source changed, an unexplained path appeared, a
Git operation is in progress, or any commit was created. Any unsafe state is `retained`.

Support:

```text
run_lock.sh acquire SKILL KEY [--ttl SECONDS] [--pid PID] [--meta JSON]
run_lock.sh resume  SKILL KEY --run-id RUN_ID
run_lock.sh touch   SKILL KEY
run_lock.sh with    SKILL KEY -- COMMAND [ARGS...]
run_lock.sh release SKILL KEY [--state finished|retained]
run_lock.sh status  SKILL KEY
run_lock.sh list    [SKILL]
run_lock.sh path    SKILL OWNER REPO KIND NUMBER
run_lock.sh resource-acquire KIND KEY --run-id RUN_ID
run_lock.sh resource-release KIND KEY --run-id RUN_ID
run_lock.sh safe    WORKTREE_PATH
run_lock.sh remove  SKILL KEY --run-id RUN_ID
run_lock.sh reap    [SKILL]
```
