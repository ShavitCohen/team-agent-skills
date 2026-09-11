# Installing the skills

The ten packages are independent directories, installable on **any agent harness** — they are
plain Markdown, shell scripts, and JSON, with no vendor metadata. There are two paths: copy the
prebuilt packages (the short way, right for almost everyone), or have a coding agent build them
from the specification (the full way).

Either way, the packages share one runtime state layout, created and owned by
[`scripts/run_lock.sh`](../spec/shared/worktrees.md#run-locks-and-registry); installing a package
must never disturb state an existing package already wrote there — a skill's private
configuration and state live outside its package, so installs and updates never touch them.

## The short way — copy the prebuilt packages

From a clone of this repository:

```bash
./install.sh --target <your skills directory>
```

`install.sh` syncs the ten packages into the target (removing files a newer version dropped),
then runs `verify.sh` on the installed copies. Updating later is `git pull` and the same command.

Where the target is, per harness:

| Harness | Target directory |
| --- | --- |
| Claude Code, per user | `~/.claude/skills` |
| Claude Code, per project | `<repo>/.claude/skills` |
| Codex CLI | the directory it loads skills/instructions from |
| OpenCode | the directory it loads skills/instructions from |
| Any other harness with a skills directory | that directory |
| A harness with **no** skill mechanism | any plain directory — then reference each package's `SKILL.md` from the agent's top-level instruction file |

The packages resolve everything by package-relative paths, so a plain directory works exactly like
a native skills directory; the only difference is how the agent discovers them.

## The full way — agent-driven build from the specification

Use this when the packages should be built and validated from the spec itself — on a harness
whose layout differs, or to audit the build. Give a coding agent this document, the specification
under [`../spec/`](../spec/README.md), and the instruction below.

### Installer prompt

```text
Read the specification under spec/ in this repository — spec/overview.md, everything under
spec/shared/, and the ten skill specifications under spec/skills/ — and install all ten skills it
specifies: create-clarity, implement, pr-review, pr-fix, manual-qa, watch-and-review,
watch-and-fix, clean-memory, orchestrate, and tickets. Build each package exactly as specified,
including its scripts and reference files, then run the validation checklist for each one and
report the installed paths.
```

### Installer instructions

Perform these steps in order.

1. **Resolve the install root for this environment.** Do not assume one. In order of preference:
   - the directory this agent already loads Agent Skills from, when it has one;
   - a project-local skills directory, when the team wants the skills versioned with the repository;
   - otherwise a plain directory chosen with the user, with each `SKILL.md` referenced from whatever
     instruction file the agent does load (for example its top-level agent instructions file).

   Report the chosen root and why. If the environment has no skill mechanism at all, install the
   packages as plain Markdown instruction files and tell the user how to point their agent at them.

2. **Install idempotently.** If a package directory already exists, show the differences and ask
   before overwriting. Never delete or overwrite a skill's private user configuration or state files;
   those belong to the user, not to the package.

3. **Create every file specified for each package**, including `scripts/`, `references/`, schemas,
   and test fixtures.

4. **Make every script executable** and confirm it.

5. **Seed shared components once per package.** The `references/policy/` files, the `schemas/`
   documents, `scripts/gh_identity.sh`, `scripts/poll_pr.sh`, and `scripts/run_lock.sh` are specified
   once in [Shared components](../spec/shared/verification.md) and shipped inside each package that lists them,
   so packages stay independently installable. Ship only the policy files a package's own tree lists;
   a package that cannot reach a workflow does not carry its policy.

   Copies of the same component must be byte-identical. Give every shared file a provenance header so
   drift is detectable rather than merely forbidden. For executable shell scripts, keep the shebang
   on the first line and put the provenance header on the second line; put the provenance header on
   the first line of every other shared file:

   ```text
   # shared-component: gh_identity.sh v1 sha256=<hash of this file with the header line removed>
   ```

   Use `<!-- shared-component: ... -->` for Markdown and a `"$comment"` member for JSON. Each
   package's `tests/validate.sh` recomputes the hash of its own copy and fails on a mismatch.

6. **Offer to seed project conventions.** Ask whether to write a
   [project conventions file](../spec/shared/conventions.md). Ship no project entries
   by default. Offer, in the same way, to seed the Orchestrate
   [lane profile](../spec/skills/orchestrate.md#lanes-and-the-profile) — which runtime and model runs each stage, the
   command line that launches the other runtime for the Reviewer, and optionally the standing
   [decision policy](../spec/skills/orchestrate.md#decision-policy--attended-or-yolo) — and ship no profile by default.

7. **Check prerequisites and report what is missing** rather than installing anything: `git` with
   worktree support, the GitHub CLI, `jq`, a filesystem that supports atomic directory creation and
   rename for [parallel runs](../spec/shared/worktrees.md#parallel-runs-and-worktree-lifecycle), and any tools required by the
   repository's selected browser-validation workflow. Missing tools are a user-facing report, not an
   install failure.

8. **Run `verify.sh` and paste its real output.** It is specified in
   [Mechanical package verification](../spec/shared/verification.md#mechanical-package-verification) and checks everything that can
   be checked without judgment. A summary of what it "would" report is not an acceptable substitute
   for its output. An installation with a failing check is incomplete, not installed-with-notes.

9. **Then work each package's prose validation checklist**, which covers the intent-level rules
   `verify.sh` cannot decide, and report results per skill: package path, files created, scripts
   executable, `verify.sh` result, prose checklist result, prerequisites present or missing.

Do not contact GitHub during installation.
