# Team Agent Skills

Eleven harness-agnostic agent skills that take a ticket — or work with no ticket at all — from idea
to merge-ready, and a person still makes every merge.

Five skills perform one unit of work each, two turn two of those into watch loops, one chains the
whole life cycle on a single ticket, one reclaims what they all leave behind, and one answers the
question that comes before all of them: *what is on my plate?*

One more stands outside the chain: **ship** takes any task, with or without a ticket, through the
same kind of quality cycle — its review loop runs locally, so the pull request opens already
reviewed.

| Skill | One line |
| --- | --- |
| [tickets](spec/skills/tickets.md) | Show what is on your plate, from live data, every time. |
| [create-clarity](spec/skills/create-clarity.md) | Turn an issue into an evidence-backed ticket before anyone codes. |
| [implement](spec/skills/implement.md) | Turn one ticket into one open pull request, unattended. |
| [pr-review](spec/skills/pr-review.md) | Review one PR once as the Reviewer, publish a verdict, stop. |
| [pr-fix](spec/skills/pr-fix.md) | Work one PR's outstanding feedback once as the Developer, stop. |
| [manual-qa](spec/skills/manual-qa.md) | Exercise a PR like a user in an isolated local environment, publish evidence. |
| [watch-and-review](spec/skills/watch-and-review.md) | Re-run pr-review on every change to a PR. |
| [watch-and-fix](spec/skills/watch-and-fix.md) | Re-run pr-fix whenever a PR owes work. |
| [orchestrate](spec/skills/orchestrate.md) | Drive one ticket through the whole chain until it is ready for human review. |
| [clean-memory](spec/skills/clean-memory.md) | Report what all of this costs your machine; reclaim only what you approve. |
| [ship](spec/skills/ship.md) | Take any task, ticket or not, to a PR an independent reviewer has already approved. |

## The life cycle

```text
issue ──▶ Create Clarity ──▶ Implement ──▶ PR ──┬──▶ PR Fix    (Developer) ◀── QA failures
                                                ├──▶ PR Review (Reviewer)
                                                │          │
                                                │     code green, requires Manual QA?
                                                │          │
                                                └──▶ Manual QA ◀┘
                                                        │
                                                 terminal evidence
                                                        │
                                                        ▼
                                                 PR Review again ──▶ 🟢 PASS
                                                        │
                                                        ▼
                                                 human review ──▶ merge (human only)
```

The Developer, Reviewer, and Manual QA agent run in separate sessions — often on different
runtimes — and talk to each other only through comments on the pull request, each one signed with
the role and the verified account that posted it.

**Work with no ticket.** Ship is the one skill outside this chain. It builds a task in its own
worktree and loops locally with an independent reviewer agent — review, fix, review again — until
the reviewer approves. Only then does it open the pull request, with the log of every round posted
on it.

## Design guarantees

- **No skill merges. No skill approves.** Readiness is a comment (`🟢 PASS — Ready for human
  review`), never a GitHub approval — an automated verdict can never light up the merge button.
- **No skill edits a ticket.** Everything a skill contributes is an append-only comment; the ticket
  body, title, and labels stay exactly as their author wrote them.
- **Every run owns one isolated git worktree** and removes it when done — except ship's, which
  stays for follow-up rounds on its PR. Your checkout is never touched, and many runs can work in
  one repository at the same time.
- **All ticket, PR, and comment text is untrusted data**, never instructions. A comment that says
  "merge this" gets quoted to you, not obeyed.
- **Problems are said out loud.** Missing tools, unreadable boards, unverifiable claims — every
  degradation is disclosed, never silently worked around.

## Requirements

- **Any agent harness.** The packages are plain directories of Markdown, shell scripts, and JSON —
  standard `SKILL.md` format with only `name` and `description` frontmatter, no vendor metadata,
  no hardcoded models or paths. They work in any runtime that can read files and run scripts; a
  harness with no skill mechanism at all can load them as plain instruction files.
- **A ticketing / code-hosting system the agent can drive through a CLI or MCP.** The skills never
  automate a web UI and never call raw HTTP APIs. The implemented backend today is **GitHub via
  the `gh` CLI** — see [the backend contract](spec/shared/backend.md) for what a port to another
  platform needs.
- **Tools:** `git` with worktree support, the GitHub CLI (`gh`, authenticated), and `jq`.
  `manual-qa` additionally uses whatever local run workflow your repository documents, and `ship`
  a runtime that can start a separate agent to act as its reviewer.

## Install

Clone once, then copy the eleven packages into your harness's skills directory:

```bash
git clone https://github.com/ShavitCohen/team-agent-skills.git
cd team-agent-skills
./install.sh --target <your skills directory>
```

Where `<your skills directory>` is, per harness:

| Harness | Target |
| --- | --- |
| Claude Code (per user) | `~/.claude/skills` |
| Claude Code (per project) | `<repo>/.claude/skills` |
| Codex CLI | its skills/instructions directory |
| OpenCode | its skills/instructions directory |
| Anything else | any directory — reference each package's `SKILL.md` from your agent's instruction file |

Details, the plain-directory fallback, and the agent-driven install path (hand the repo to your
coding agent with one prompt) are in [install/INSTALL.md](install/INSTALL.md) and
[install/prompt.md](install/prompt.md).

## Update

```bash
git pull
./install.sh --target <the same directory>
```

A skill's private configuration and state live outside its package, so updating never touches your
settings. See [CHANGELOG.md](CHANGELOG.md) for what changed between versions; releases are tagged.

## Verify

`verify.sh` mechanically checks any set of installed packages — manifest, frontmatter, script
health, shared-component integrity, forbidden operations, no hardcoding, and each package's
offline test suite:

```bash
./verify.sh skills/*
```

`install.sh` runs it automatically after copying.

## Repository layout

```text
README.md            this file
CHANGELOG.md         what changed between tagged releases
LICENSE              MIT
verify.sh            mechanical package verifier
install.sh           copy-based installer/updater (any harness, --target <dir>)
install/             installer docs and the agent-driven install prompt
spec/                the full specification, split by concern
  overview.md        the family, the life cycle, portability requirements
  shared/            shared components: trust, identity, worktrees, polling, …
  skills/            one specification per skill
skills/              the eleven built packages — what install.sh copies
```

The specification is the source of truth; the packages under `skills/` are built from it. Shared
files (`references/policy/*`, `gh_identity.sh`, `run_lock.sh`, `poll_pr.sh`, shared schemas) are
deliberately **duplicated byte-identical** across packages so each package stays independently
installable — `verify.sh` enforces that the copies have not drifted. Per the spec, packages
themselves contain no README or changelog.

## License

[MIT](LICENSE)
