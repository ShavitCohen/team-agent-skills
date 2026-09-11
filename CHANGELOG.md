# Changelog

All notable changes to the Team Agent Skills are recorded here. Releases are tagged; update with
`git pull` and re-run `./install.sh --target <your skills directory>`.

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
