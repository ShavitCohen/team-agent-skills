# Changelog

All notable changes to the Team Agent Skills are recorded here. Releases are tagged; update with
`git pull` and re-run `./install.sh --target <your skills directory>`.

## Unreleased

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
