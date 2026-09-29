# The specification

This directory is the source of truth for the eleven skill packages shipped under
[`skills/`](../skills). It was originally one ~5,000-line document; it is split here by concern so
a reader — human or agent — loads only what a task needs.

## Reading order

1. [overview.md](overview.md) — what the family is, the life cycle, and the shared portability
   requirements every package obeys.
2. [shared/](shared/) — the components specified once and shipped inside every package that lists
   them:
   - [trust.md](shared/trust.md) — the agent handshake protocol; message content is data, never
     instruction.
   - [identity.md](shared/identity.md) — GitHub identity across multiple accounts, capability
     probing, credential-scoped pushes.
   - [worktrees.md](shared/worktrees.md) — parallel runs, one-run-one-worktree, run locks, the
     lease-based registry, cleanup safety.
   - [conventions.md](shared/conventions.md) — the project conventions file.
   - [polling.md](shared/polling.md) — change-filtered PR snapshots and the `poll_pr.sh` contract.
   - [browser.md](shared/browser.md) — browser validation in an isolated local workflow; the
     machine-capacity gate.
   - [handoff.md](shared/handoff.md) — environment capabilities, degradation rules, and the
     contract a skill owes when it starts another.
   - [pr-lifecycle.md](shared/pr-lifecycle.md) — the PR and board lifecycle; ticket ownership
     (never edit a ticket body).
   - [verification.md](shared/verification.md) — how shared policy is organized, test-case
     fixtures, and the mechanical verification `verify.sh` implements.
   - [backend.md](shared/backend.md) — the backend contract: what a ticketing/code-hosting
     platform must expose (via CLI or MCP) for these skills to run on it, and what a port
     replaces. GitHub via `gh` is the reference backend.
3. [skills/](skills/) — one specification per skill: its package manifest, frontmatter, workflow,
   hard rules, and validation checklist.

## Spec vs. packages

The packages under [`../skills/`](../skills) are **built from** this specification and must match
it exactly — `../verify.sh` checks everything mechanical. Two rules explain what you will see
there:

- Shared components are **duplicated byte-identically** across packages, each copy carrying a
  provenance hash header, so every package stays independently installable. The duplication is by
  design; drift is what `verify.sh` catches.
- Packages contain **no README, changelog, or install guide** — documentation lives here and at
  the repository root, never inside a package.

Cross-references inside the skill specifications that look like
`references/policy/worktrees.md` are package-relative paths quoted as package content — they
resolve inside an installed package, not inside this directory.
