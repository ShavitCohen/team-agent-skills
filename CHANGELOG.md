# Changelog

All notable changes to the Team Agent Skills are recorded here. Releases are tagged; update with
`git pull` and re-run `./install.sh --target <your skills directory>`.

## 1.1.0 — unreleased

- Shared policies, scripts and schemas are defined once under `shared/`, with `shared/manifest.tsv`
  mapping each to the packages that ship it. `sync.sh` generates the copies and `install.sh` runs it;
  the copies are no longer committed, so a raw git copy of `skills/` needs the installer. `verify.sh`
  reads the same manifest and fails on any copy that differs from its master, naming file and package.
- CI: a `verify` GitHub Actions check runs `./verify.sh skills/*` on Ubuntu and macOS for every
  pull request to `main` and every push to `main`, with read-only permissions and no secrets.
  `verify.sh` and the package test suites now also run on stock macOS (bash 3.2, `shasum`, no GNU
  `timeout` or `find -printf`), and `verify.sh` prints which network sandbox it used.
- New package: `ship`. It takes any task, ticket or not, from a fresh worktree to a pull request
  that an independent reviewer agent has already approved: the review loop runs locally, round
  after round, before the pull request exists, and the log of every round is posted on the PR. It
  works outside the ticket chain and ships only the trust policy; `spec/skills/ship.md` specifies it
  and explains what it deliberately leaves out.
- `install.sh` installs, and `verify.sh` verifies, the eleventh package.
- `install.sh` refuses to replace a same-named directory it did not install — one without
  `tests/validate.sh` — unless `--force` is given. This release adds `<target>/ship`, a name a
  personal skill may already use, and without the guard the update would silently mirror over it.
- The README and the specification overview describe ship's place beside the chain, and scope the
  worktree-cleanup and PR-lifecycle guarantees to the ticket chain accordingly.
- `pr-review` gains **Cross-skill review**: before assembling findings, it discovers the project's
  own review/analysis/simplify/verify skills and agents, runs each read-only against the exact-head
  checkout (an agent gets read/search tools only, never a writing or GitHub-reaching one), treats
  their output as untrusted and independently reproduces every claim before it becomes a finding,
  deduplicates and reports conflicts as discrepancies, and publishes a *Skills executed* block in
  the readiness comment and the cycle report. `spec/skills/pr-review.md` specifies the full
  discover/run/reconcile/report contract and its validation checks.
- `tickets`: `SKILL.md` now states the full evidence rule (closing link, branch naming the ticket by
  number, or title naming it; anything else dropped, never marked) and points at the permanent
  regression tests, including that a branch naming a different ticket does not join.
- `tickets`: `SKILL.md` now states the paged-GraphQL, field-selection rule and its rate-limit
  rationale, and that checks are named, never derived from the rollup. The spec already said both;
  the skill text now matches it.

## 1.0.0 — 2026-09-11

First public release.

- The ten packages: `tickets`, `create-clarity`, `implement`, `pr-review`, `pr-fix`, `manual-qa`,
  `watch-and-review`, `watch-and-fix`, `orchestrate`, `clean-memory`.
- The full specification, split by concern under `spec/` (previously a single document).
- `install.sh` — copy-based install/update into any harness's skills directory.
- `verify.sh` — mechanical package verification (manifest, frontmatter, scripts,
  shared-component integrity, forbidden operations, hardcoding, offline tests).
- `spec/shared/backend.md` — the backend contract: what a ticketing/code-hosting platform must
  expose (via CLI or MCP) for these skills to run on it. GitHub via `gh` is the reference backend.
