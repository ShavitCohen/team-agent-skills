# The backend contract

*What a ticketing / code-hosting platform must expose for these skills to run on it.*

The skills never automate a web UI and never call raw HTTP APIs. Every platform operation goes
through a command-line tool the agent can run — or, equivalently, an MCP server exposing the same
operations as tools. That is a deliberate design boundary: it concentrates the entire platform
dependency in a thin, replaceable layer, keeps every operation auditable as a command, and lets
the identity wrapper scope credentials per invocation.

**The implemented backend today is GitHub, driven by the `gh` CLI.** The packages as shipped are
GitHub-bound: their reference commands, identity script, poller, and lifecycle mapping all speak
`gh`. GitHub is the reference backend, not the design boundary — everything below describes what a
port to another platform (GitLab, Gitea, a Jira-plus-forge pairing, …) must provide and what it
would replace.

## What the platform must expose

A backend qualifies when the agent can perform all of this through a CLI or MCP, non-interactively,
with pagination on every collection:

- **Tickets (issues).** Read a ticket's body, state, labels, assignees, milestone, comments, and
  timeline/cross-references; append a comment. The skills never need to edit a ticket — by rule
  they refuse to — so ticket *write* access beyond commenting is not required.
- **Pull/merge requests.** Read metadata (state, draft flag, base/head branches and SHAs,
  mergeability, review decision), the diff, reviews, review threads with stable identifiers,
  thread replies, and top-level comments. Write: comment, submit a review (comment and
  request-changes variants), reply in a thread, resolve/unresolve a thread, convert draft ↔ ready,
  request a reviewer. Approving and merging are **never** required — no skill does either.
- **Checks/CI.** Read named check results per commit — individual contexts, not only an aggregate
  rollup, because a rollup that calls a cancelled job a failure cannot be reported honestly.
- **Identity.** Multiple authenticated accounts side by side; a way to verify which login a
  credential belongs to; per-invocation credentials (run one command as one account without
  switching any global state). This is what `gh auth token` / `GH_TOKEN` provide on GitHub.
- **Git interop.** The forge hosts ordinary git branches the agent can push to with
  credential-scoped `git push` — needed by `implement`, `pr-fix`, and their watchers.
- **Project board (optional).** A readable/movable status field for tickets. Every skill that
  touches board status degrades explicitly when the board is unreadable, so a backend without one
  still works.

## The layer a port replaces

The platform dependency is deliberately confined to these files — everything else (worktree
discipline, run locks, the handshake protocol, trust rules, the cycle/loop split, orchestration)
is platform-neutral and unchanged:

| File | Role | In a port |
| --- | --- | --- |
| `scripts/gh_identity.sh` (all packages that write) | Account resolution, capability probing, credential-scoped command execution and `git-push` | Reimplement against the platform's CLI/MCP and credential mechanism, same subcommand contract |
| `scripts/poll_pr.sh` (PR-handling packages) | Change-filtered PR snapshots with fingerprints and cursors | Reimplement against the platform's PR/MR reads, same snapshot schema (`schemas/poll-snapshot-v1.json`) and exit-code contract |
| `references/gh-commands.md` (implement, pr-fix, pr-review) | The exact per-skill command invocations | Rewrite for the platform's CLI/MCP |
| `references/policy/pr-lifecycle.md` | Draft/ready, reviewer-request, and board-status state mapping | Re-map to the platform's equivalents |
| `tickets/scripts/fetch_tickets.sh` | The two paged searches behind the worklist | Reimplement against the platform's search |
| `references/policy/identity.md` | The written identity policy | Adjust platform specifics; the rules stay |

A port keeps every behavioral contract: snapshots keep their schema and fingerprint semantics,
the identity wrapper keeps its subcommands and its never-switch-global-state rule, readiness stays
a comment and never an approval, and all platform text stays untrusted data.

## MCP instead of a CLI

Where a tracker offers MCP but no CLI, the same contract applies: the operations above become MCP
tool calls, and the shipped shell scripts are replaced by equivalents the harness can execute
against that server. What must survive the translation is the *shape* — per-invocation identity,
paginated complete reads, change detection outside the model, and writes limited to the classes
each skill's own rules allow.

## Status

GitHub is the only implemented backend. Ports are welcome — a port that replaces the table above
and passes each package's validation checklist (with platform-appropriate fixtures under
`tests/fixtures/`) is a faithful member of the family.
