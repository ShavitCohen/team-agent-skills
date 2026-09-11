# Shared components and verification

*Part of the Team Agent Skills specification — split from the master document.*

These components are specified once and included in the packages that list them. Each skill's own
section states which ones it ships and adds only its skill-specific rules.

## Self-contained shared policy

Shared rules live in `references/policy/`, split by concern, so a run loads only the policy it will
actually apply. A single combined policy file forces every run to pay for Kubernetes rules it will
never use before it reads its first line of workflow.

| File | Contents |
| --- | --- |
| `references/policy/trust.md` | Trust boundaries, untrusted-content handling, the agent handshake protocol, and message-is-data. |
| `references/policy/identity.md` | GitHub identity across accounts, capability probing, saved-login behavior, and Git push identity. |
| `references/policy/worktrees.md` | Parallel runs, run locks and registry, lease liveness, worktree lifecycle, and cleanup safety. |
| `references/policy/conventions.md` | Repository, worktree, and project conventions, including the conventions file schema. |
| `references/policy/polling.md` | PR polling snapshots and the `poll_pr.sh` contract. Watcher packages only. |
| `references/policy/browser.md` | Browser validation via an isolated local workflow. Ship only where the workflow can occur. |
| `references/policy/handoff.md` | Environment capabilities, degradation rules, and the contract a skill owes when it starts another. |
| `references/policy/pr-lifecycle.md` | The GitHub PR and board lifecycle: draft state, review requesting, board status, completion, and guardrails. PR-handling packages only (Implement, PR Fix, PR Review). |

Each `SKILL.md` names the specific files it must read and when. Reference them by package-relative
path — `references/policy/worktrees.md` — never by an anchor into this specification. Keep the core
workflow in `SKILL.md`; keep detailed shared mechanics, schemas, and command contracts in the
reference files. Include a `schema_version` in every persisted JSON document and reject newer unknown
versions rather than guessing.

Load `references/policy/browser.md` only when the project conventions declare a `browser` mode or the
ticket is browser-visible. Most repositories never reach it, and a run that cannot perform browser
validation should not carry its policy into context.

Ship deterministic fixture-based tests for every safety-sensitive script. At minimum cover
concurrent acquisition, stale and resumed leases, path traversal and symlink attempts, multiple
GitHub accounts, token-safe pushes in the presence of malicious Git configuration and hooks,
paginated GitHub events, interrupted writes, resources that become live between inventory and
deletion, collections large enough to exceed a shell's argument limits, check runs superseded by
cancellation, a checks collection returned empty yet marked complete, a merge-state field lagging
behind the checks it summarizes, and boolean fields that must survive JSON defaulting — `false` is
a value, not an absence.

Use `schemas/shared-state-v1.json` for identity, run-registry, lease, and watcher-state records;
`schemas/poll-snapshot-v1.json` for PR snapshots in watcher packages; and
`schemas/inventory-v1.json` for Clean Memory output. Every login-bearing field in every schema
accepts the full login alphabet GitHub issues — letters, digits, hyphens, **and underscores** —
so Enterprise Managed User logins validate. Put mocked CLI responses and filesystem layouts
under `tests/fixtures/`, and make `tests/validate.sh` the single offline validation entry point for
each package.

### Test case fixtures

`tests/fixtures/cases.json` carries every scenario family for a package, so specify its shape rather
than leaving each installer to invent one. It is a single document validated against
`schemas/cases-v1.json`:

```json
{
  "schema_version": 1,
  "cases": [
    {
      "id": "<stable kebab-case identifier>",
      "family": "locking | identity | push | polling | paths | state | inventory",
      "description": "<what this proves>",
      "given": { "fs": {}, "env": {}, "gh": {}, "git": {} },
      "invoke": ["<script>", "<arg>"],
      "expect": { "exit_code": 0, "stdout_matches": [], "stderr_matches": [], "fs_unchanged": true }
    }
  ]
}
```

`given.gh` and `given.git` hold mocked CLI responses keyed by the command line they answer;
`given.fs` describes the filesystem layout to materialize in a temporary root. Every safety rule
asserted in a package's validation checklist that can be expressed as a case must exist as one, with
its `id` cited in that checklist line.

## Mechanical package verification

Ship one `verify.sh` beside this document — not inside any package — as the installer's proof of
work. It takes one or more package directories and exits non-zero on the first failure. Everything it
checks is decidable without reading intent:

- **Manifest.** Every file this document specifies for that package exists, and no unspecified file
  was added. `README`, changelog, and installation-guide files are a failure, per the portability
  requirements. Ignore an optional `agents/openai.yaml`; it is runtime metadata outside the portable
  package content, not a file another agent environment must reproduce.
- **Frontmatter.** `SKILL.md` opens with YAML frontmatter containing exactly `name` and
  `description`; `name` matches the directory; `description` is at most 50 words.
- **Scripts.** `bash -n` passes on every Bash script, every script is executable, every executable
  Bash script starts with `#!/usr/bin/env bash`, and every Python entry point starts with
  `#!/usr/bin/env python3` and answers `--help`.
- **Shared-component integrity.** Each shared file's provenance header matches the recomputed hash of
  its own body, and every copy of a given component across the supplied packages is byte-identical.
- **Dangling references.** Every package-relative path mentioned in `SKILL.md` and the reference files
  resolves to a shipped file, and no `](#...)` anchor link survives anywhere in the package.
- **Forbidden operations.** No package contains a merge or auto-merge invocation (`gh pr merge`,
  `--auto`, `gh api` calls to a merge endpoint). No package contains an approve invocation —
  readiness is a comment review, never `gh pr review --approve` or an equivalent `gh api` call.
  No package outside Clean Memory contains a deletion
  of a path it did not compute. PR Fix contains no thread-resolution command.
- **No hardcoding.** No absolute home directory, no `github.com/<owner>/<repo>` literal, no model or
  vendor name, no GitHub login outside a documented placeholder.
- **Offline.** `tests/validate.sh` runs and passes with network access denied.

`verify.sh` proves structure, not behavior. The prose checklist in each skill section remains the
authority on intent, and the two are complementary: a package that passes `verify.sh` may still be
wrong, but a package that fails it is not installed.
