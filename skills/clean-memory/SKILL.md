---
name: clean-memory
description: Inventory what this project and its agent skills cost the machine — worktrees, clusters, containers, dependencies, processes — then reclaim only what the user approves item by item. Read-only by default. Use when the user asks to reclaim project disk space or clean up leftovers. Not for RAM diagnosis.
---

# Clean Memory

Answer two questions and act on the second: **what is this project costing this machine right now**, and
**what can be reclaimed without destroying work or interrupting an agent that is still running?**

This is a reporting skill that can delete, not a cleaner that reports. The default posture is read-only.
Nothing is removed without the user seeing it, its size, its owner, and the exact command.

At the start of every run, read `references/policy/worktrees.md` for lease liveness, ownership, path
safety, and cleanup rules, then `references/policy/trust.md`, `references/policy/conventions.md`, and
`references/policy/handoff.md`. Read `references/policy/browser.md` before inventorying or reclaiming any
local-environment resource.

## Boundaries

- Inventory first, always. Never delete before showing the full inventory.
- Ask the user to select exact items within each group, never once for everything. There is no blanket
  clean, and group approval is not approval for every candidate in that group.
- Never delete uncommitted or unpushed work.
- Never delete a resource this family of skills did not create, unless the user names it explicitly.
- Never delete a Kubernetes cluster. Never delete a namespace, volume, workload, service, container, or
  image unless deterministic labels or registry evidence prove that this skill family created it.
- Never use force or recursive deletion on a path the skill did not itself compute.
- Never kill a process the skill cannot attribute to this project's agent work.
- Report measured sizes. When a size cannot be measured, say so rather than estimating.
- Removal is not the only outcome. Point retained work back at the skill that owns it.

## Scope of the inventory

Determine the project in scope — the repository or workspace the user is asking about, defaulting to the
current one — then run:

```bash
scripts/inventory.sh --project "<project path>"
```

It is read-only and emits JSON validated against `schemas/inventory-v1.json`, covering these groups. A
group whose tooling is absent is reported as skipped, with the reason.

1. **Skill worktrees and managed clones** — every worktree and clone under the skills' state layout, read
   from the run registry via `scripts/run_lock.sh list`.
2. **Git artifacts in the project** — stale worktree registrations, loose-object and pack sizes,
   garbage-collection candidates, and local branches already merged into the default branch. User-created
   branches and repository-wide garbage collection stay informational unless the user explicitly names
   the item; skill ownership is never inferred from a repository path.
3. **Kubernetes** — namespaces and releases created by browser validation, plus failed, evicted, and
   completed pods, unbound volume claims, and stopped workloads attributable to this project.
4. **Container images and build caches** — project images with deterministic ownership labels, dangling
   layers attributable to those images, and builder-cache measurements. Global or unattributable builder
   caches are protected informational items; a global prune is never invoked.
5. **Project dependency and build output** — dependency directories, virtual environments, build and
   distribution output, coverage and test artifacts, inside the project and its worktrees.
6. **Skill state, scratch, and logs** — per-run temporary directories, snapshots, and log files. Saved
   identity mappings, project conventions, current registry records, schemas, and configuration are
   always protected.
7. **Processes and ports** — dev servers, port-forwards, watchers, and background agent workers holding
   this project's ports or files.

For every item record: identifier or path, measured size or count, owning skill and run when known,
last-modified or last-seen time, and its classification.

## Live-work awareness

This is the rule that makes the skill safe to run while other agents are working. Every item is
classified **before** it is shown:

- **`in use`** — owned by a run whose lock is live, or a Kubernetes resource belonging to such a run, or
  a path held open by a running process. **Protected.** Display it so the user knows why the space is not
  reclaimable, but never offer it for deletion.
- **`holds work`** — a worktree with uncommitted changes or commits not on its remote, or a registry
  entry marked `retained`. **Protected.** Show exactly what it holds and route it back to the owning
  skill. Never offer it for deletion.
- **`stale`** — registered, its lease is past its time-to-live, nothing is unsaved, **and** no running
  process holds its path or has it as a working directory. All three are required. Expiry alone means a
  run stopped heartbeating, which is not the same as the run having stopped — a long test suite, a slow
  deployment, or a paused runtime is indistinguishable from abandonment in the registry alone. Candidate
  only when all three hold; otherwise `unknown`.
- **`orphan`** — no registry entry exists, but canonical containment plus deterministic project, skill,
  and run ownership labels prove this skill family created it. Candidate. Without that proof, classify it
  `unknown`, not orphan.
- **`unknown`** — ownership or liveness cannot be determined. **Protected**, and reported as such.

Default to protected. An unnecessary leftover costs disk; a wrong deletion costs work.

Name the live runs explicitly in the report, so the user understands what is holding what — for example,
that a Watch and Fix run is watching a given pull request and owns that worktree, or that an Implement
run is mid-build on a given issue. Read this from the registry; never infer it from a path.

**State the limit of this awareness.** Liveness is read from this skill family's own run registry, so
only these seven skills' runs are visible as runs. Another agent, another runtime, another user account, or
a developer's own editor holding a checkout is invisible to the registry and reaches this report only
through the process and open-file checks. Say so in the report rather than implying the inventory has
seen everything on the machine. This is also why `unknown` is protected: it is the classification that
covers the work this skill cannot see.

## Report and approval

1. Present the inventory grouped, each group sorted by reclaimable size, with a per-group and overall
   total, and a separate total for what is protected and why.
2. Ask the user to select exact candidate identifiers within each group. Default to selecting nothing.
3. Show the exact commands before running them.
4. **Re-verify liveness immediately before each deletion.** A run can start between inventory and
   approval; anything that became live or gained unsaved work is skipped and reported, not removed.
5. Delete one item at a time:

   ```bash
   scripts/reclaim.sh --item "<exact item id from the inventory>" --project "<project path>"
   ```

   Stop at the first error rather than continuing through a broken assumption. `--dry-run` prints the
   exact command without performing it.
6. Report what was reclaimed, what was skipped, and why — with the space actually recovered, measured
   again rather than assumed.

## Helper scripts

`scripts/inventory.sh` is **read-only** and emits the classified inventory as JSON. It never deletes,
kills, or mutates anything, so it is safe to run at any time, including while other agents work.

`scripts/reclaim.sh` performs **one** approved removal per invocation. It re-runs the inventory to
re-check liveness and safety for that item, refuses anything classified protected, refuses a path outside
the skills' state layout or the named project, and exits non-zero with a reason rather than proceeding on
doubt.

Before Kubernetes inventory or reclamation, apply the environment check in `references/policy/browser.md`
and fail closed unless the context is positively local and single-user. Before terminating a process,
revalidate its identifier, start time, command, working directory, open project files, ports, and owning
run to prevent identifier reuse or attribution mistakes. Request graceful termination first, and never
escalate to force without a new, item-specific approval.

## Retained work belongs to its owner

Never delete retained work: an Implement worktree held back by a circuit breaker should be resumed or
its branch pushed, not discarded. Name the skill that owns it and leave the decision to finish or
reclaim it with the user, per `references/policy/handoff.md`.
