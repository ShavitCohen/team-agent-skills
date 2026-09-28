# Changelog

All notable changes to the Team Agent Skills are recorded here. Releases are tagged; update with
`git pull` and re-run `./install.sh --target <your skills directory>`.

## 1.1.0 — unreleased

- New package: `ship`. It takes any task, ticket or not, from a fresh worktree to a pull request
  that an independent reviewer agent has already approved: the review loop runs locally, round
  after round, before the pull request exists, and the log of every round is posted on the PR. It
  works outside the ticket chain and ships only the trust policy; `spec/skills/ship.md` specifies it
  and explains what it deliberately leaves out.
- `install.sh` installs, and `verify.sh` verifies, the eleventh package.
- The README and the specification overview describe ship's place beside the chain, and scope the
  worktree-cleanup and PR-lifecycle guarantees to the ticket chain accordingly.

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
