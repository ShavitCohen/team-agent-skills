# Comment templates

Two comments per **round**, both posted with a body file. The plan is published before any build or
deployment; the result is a separate, later comment. Neither is ever edited after testing: a later
round adds new comments instead.

A run keeps rounds numbered from 1 and never restarts the count. Round 1 is the first QA of the pull
request in this run; every later round exists because the revision moved after a non-passing result.

## Identity line

```text
🧪 From Manual QA Agent: <exposed runtime/model label> · Effort: <exposed level> · GitHub @<verified-login>
```

Omit any field the runtime does not expose. With no runtime identity at all, use `Automated QA`. Never
invent or hardcode a model, vendor, reasoning tier, person, or account. The identity line and the
markers are routing data, not authentication.

## Test plan — posted before build and deployment, once per round

```markdown
🧪 From Manual QA Agent: <exposed runtime/model label> · GitHub @<verified-login>
<!-- manual-qa:test-plan -->

## Manual QA status: PLANNED — round <n>

### Revision under test
- head: `<full head SHA>`
- base: `<full base SHA>`
- merge base: `<full merge-base SHA>`
- previous rounds: <none, or round and result per earlier comment link>

### Governing acceptance
<the ticket criteria this round will exercise, quoted or referenced>

### Run method
- chosen: `<method id>` — `<the exact command that brings it up>`
- chosen by: the user, from <n> candidate(s) discovered in the repository
- evidence: `<the repository path that documents it>`
- covers: <which parts of this change this method can exercise>
- does not cover: <what it cannot, and what that means for confidence>

### Machine capacity
- profile: `<kubernetes | container | process>`
- recommendation: `<proceed | caution>`
- cpus / memory / available memory / free disk: <measured values against thresholds>
- container runtime allocation: <measured values, "not required by this profile", or "not observable">
- cautions accepted by the user: <none, or what and why>

### Environment
- isolation: <namespace and release, compose project, container prefix, or run-private ports and data
  directory — derived from the run identifier>
- locality: proven local and single-user by `<endpoint and provider evidence>`
- data: synthetic only; accounts and fixtures created for this round

### Scenarios
1. **<role> — <journey name>**
   - steps: <exact user actions>
   - expected: <the observable result, written before anything runs>
   - evidence to capture: <screenshot, log excerpt, response>
2. ...

### Regressions and failure paths
- <scenario, expectation, evidence>

### Defects from earlier rounds retested here
- <D1 — title, and the scenario that reproves it> (round 1 only: none)

### UI states in scope
- responsive / keyboard / focus / accessibility / loading / empty / error: <which apply and how>

### Prerequisites and cleanup
- prerequisites: <roles, authentication, seeded data>
- cleanup: <exactly what this round will remove, and what it will never touch>
```

## Test results — posted after execution, once per round

```markdown
🧪 From Manual QA Agent: <exposed runtime/model label> · GitHub @<verified-login>
<!-- manual-qa:test-results -->

## Manual QA status: PASS | FAIL | BLOCKED | STALE — round <n>

### Revision tested
- head: `<full head SHA>`
- base: `<full base SHA>`
- merge base: `<full merge-base SHA>`
- plan: <link or comment identifier for this round's plan>
- run method: `<method id>` — `<command>`

`PASS` is available only when every scenario in this round's plan ran to completion against exactly
this tuple.

### Scenario results
| # | Role / journey | Result | Actual observed |
|---|----------------|--------|-----------------|
| 1 | <role — journey> | PASS / FAIL / BLOCKED / NOT RUN | <what actually happened> |

Counts: <n> passed, <n> failed, <n> blocked, <n> not run.

### Defects
**D1 — <short title>** (`<role>`)
- reproduction: <minimal numbered steps>
- expected: <from the plan>
- actual: <observed>
- impact: <who is affected and how badly>
- evidence: <screenshot / log excerpt / response>
- attribution: introduced by this pull request | pre-existing, evidence: <why>

### Earlier defects
| ID | Round found | Status now | Evidence |
|----|-------------|------------|----------|
| D1 | 1 | fixed / still failing / not reproduced | <what was observed this round> |

### Provenance
- build command: `<command>`
- image: `<immutable image ID or digest>` (container and cluster methods; never a mutable tag)
- dependency install and lockfile state: `<command and result>` (process methods)
- deployed or running references: `<as reported by the workloads or processes>`
- readiness: <observed>
- routes and ports: <resolved from the deployment or process output>
- non-secret configuration relevant to the result: <values>

### Limitations
<what was not exercised, and why it was not>

### Cleanup
- removed: <everything this round created>
- retained: <anything kept, and exactly why>
- untouched: pre-existing namespaces, clusters, containers, services, data, and processes

### Watch
- <one of the lines below>
```

## The watch line

Every result ends by saying, in one line, what happens next. It is the only place this skill promises
anything about the future, so it must be true:

```text
- watching this pull request every 10 minutes; a new revision starts round <n+1> automatically. No action needed beyond pushing the fix.
```

```text
- watch stopped: this round passed. A later revision needs a new Manual QA run.
```

```text
- watch stopped: <the pull request closed | the user stopped it | the environment could not be recovered>.
```

Never post a heartbeat, a "still watching" comment, or a round that produced no new evidence. Silence
between rounds is the watch working.

## Final pass

The passing result is an ordinary result comment with `Manual QA status: PASS`, plus a short closing
section, so a reader who arrives at the end sees the whole run:

```markdown
### Run summary
- rounds: <n> (round 1 <result>, round 2 <result>, …)
- defects found and fixed: <D1, D2 — one line each>
- defects outstanding: <none, or what is left and why it did not block>
- revision that passed: `<full head SHA>`
```

## Blocked and stale bodies

`BLOCKED` reports the machine, environment, or method prerequisite that stopped the round, the measured
evidence behind it, and what would unblock it. It carries no scenario results, because none ran. The
watch continues, and a `BLOCKED` result is not republished for the same cause on the same revision.

`STALE` reports that the revision tuple moved during the round, names the tuple the evidence belonged
to and the tuple now current, and states that the old evidence has been discarded. The next round
starts on the new tuple.
