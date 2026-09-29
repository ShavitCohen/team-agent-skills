# Install prompts

Two ways to install with a coding agent. Both assume the agent can read files and run shell
commands in the directory where you cloned this repository.

## The short way — copy the built packages

Use this on any harness with a skills directory. Paste into your agent, run from the clone:

```text
This repository ships eleven prebuilt agent-skill packages under skills/. Resolve the directory this
environment loads Agent Skills from (ask me if you cannot determine it), then run
./install.sh --target <that directory> and show me its output, including the verify.sh results.
If install.sh refuses to replace a directory it did not install, show me its message and ask me
what to do; never pass --force or move my files yourself.
If this environment has no skills directory, install into a plain directory instead and tell me
how to reference each package's SKILL.md from this agent's instruction file.
```

To update later, the same prompt works after `git pull` — `install.sh` synchronizes the installed
copies and re-verifies them.

## The full way — build from the specification

Use this when the packages should be built and validated from the spec itself — for example on a
harness whose package layout differs, or to audit the build. Paste into your agent, run from the
clone:

```text
Read the specification in this repository — spec/overview.md, everything under spec/shared/, and
the eleven skill specifications under spec/skills/ — together with install/INSTALL.md, and install
all eleven skills it specifies: create-clarity, implement, pr-review, pr-fix, manual-qa,
watch-and-review, watch-and-fix, clean-memory, orchestrate, tickets, and ship. Build each package
exactly as specified, including its scripts and reference files, then run ./verify.sh on every
package and each package's prose validation checklist, and report the installed paths and results.
```

The installer steps the agent must follow — resolving the install root for its own environment,
installing idempotently, seeding shared components byte-identically with provenance headers, and
verifying — are specified in [INSTALL.md](INSTALL.md).
