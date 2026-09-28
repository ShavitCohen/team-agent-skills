# Review log and PR comment

Keep `/tmp/ship-<branch>/review-log.md` current during the loop, updating it after every round, and turn it into the PR comment at the end. Writing it as you go means nothing has to be reconstructed from memory, and it survives context compaction.

## Running log format

```text
Reviewer agent ID: <id>   (internal: never goes into the comment)
Reviewer continuity: one agent, kept its context | restarted each round (the runtime can't message a started agent)
Base: origin/main @ <sha>   (update after merging main; it is <prev-main> for the next merge round)

## Round 1: reviewed <sha>, REQUEST_CHANGES
- R1.1 [major] <title> (path:line) -> fixed in <sha>: <how, one line>
- R1.2 [minor] <title> -> declined: <reason>. Reviewer agreed.
- R1.3 [nit] <title> -> fixed in <sha>
Verification: failed (<what>) -> fixed in <sha>; passed on <sha>

## Round 2: reviewed <sha>, APPROVE with 1 note worth fixing
- R2.1 [minor] <title> -> fixed in <sha>
Verification: passed on <sha>

## Round 3: reviewed <sha>, APPROVE, no findings
Verification: passed on <sha>
```

## The PR comment

```markdown
## Review–fix log

Before this PR was opened, an independent reviewer agent reviewed it over **<N> rounds**. <How it ended, e.g. "Round 3 approved with nothing left worth fixing."> <Only if the reviewer was restarted each round: "Each round used a fresh reviewer, given the log of the rounds before it.">

| Round | Commit reviewed | Verdict | Findings | Outcome |
|---|---|---|---|---|
| 1 | abc1234 | Changes requested | 2 major · 5 minor · 3 nits | 9 fixed · 1 declined |
| 2 | def5678 | Approved with notes | 1 minor | Fixed |
| 3 | 0a1b2c3 | Approved | None | — |

<details>
<summary><b>Round 1</b>: changes requested (2 major, 5 minor, 3 nits)</summary>

- **R1.1 Major**: <what was wrong, in words a reader of this PR understands> (`path/to/file.ts`). **Fixed** in 4f5e6d7: <how>.
- **R1.2 Minor**: <…>. **Declined**: <reason>. <Reviewer agreed. | Decided by the user: …>

</details>

<one details block per round that had findings; rounds without findings appear only in the table>

**`main` moved during review:** <only if it did: merged at <sha>, what it touched, and the round that reviewed the merge>

**Verification:** <command> passed on <final sha>. <What wasn't verified and why, e.g. not seen in a browser.>
```

## Rules for the comment

- Every finding appears exactly once, with its outcome, and the counts in the table match the details.
- Write for someone reading the PR, not in the reviewer's shorthand: one or two lines per finding.
- Keep declined findings and their reasons. For whoever merges, those are the most useful lines here.
- Every short SHA must be a commit on the pushed branch. Write SHAs as plain text, not in backticks, so GitHub links them to the commit.
- Nothing secret or personal: no tokens, passwords, test credentials, customer data, or the reviewer's agent ID.
- In a public repo (`gh repo view --json visibility -q .visibility`), don't publish exploitable detail of a security problem that exists on `main`, whether or not this PR fixes it. Describe it generically ("a pre-existing authorization gap in the export route: fixed") and give the user the details in chat.
