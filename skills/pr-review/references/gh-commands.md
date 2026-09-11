# Reference commands

Every GitHub call goes through `scripts/gh_identity.sh`. Placeholders are written `<like-this>`; nothing
here hardcodes a login, a home directory, or a repository. This file contains no approve, merge, push,
close, edit, or mark-ready command. Its only lifecycle writes are the one-directional repairs: Ready
back to Draft, and the linked ticket's project status.

## Parse the target

```text
https://github.com/OWNER/REPOSITORY/pull/NUMBER   ->  owner, repository, number
OWNER/REPOSITORY#NUMBER                           ->  owner, repository, number
```

## Select an identity

```bash
scripts/gh_identity.sh select --need read "<owner>/<repository>#<number>"
scripts/gh_identity.sh select --need write "<owner>/<repository>"
```

Hyphenated owners and repository names are ordinary input here; nothing splits on a hyphen.

## Head, base, and merge base

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh pr view "<number>" --repo "<owner>/<repository>" \
  --json headRefOid,baseRefOid,baseRefName,headRefName,mergeable,mergeStateStatus,reviewDecision,state,isDraft

git -C "<review-checkout>" merge-base "<base-sha>" "<head-sha>"
```

Re-run this preflight immediately before every write. A changed tuple invalidates positions and
evidence.

## Governing tickets

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh api graphql -f query='
    query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        pullRequest(number:$number){
          closingIssuesReferences(first:20){ nodes { number url title body } }
        }}}' -F owner="<owner>" -F name="<repository>" -F number=<number>
```

## Lifecycle facts, read-only

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh pr view "<number>" --repo "<owner>/<repository>" \
  --json isDraft,state,reviewRequests,reviewDecision,url,closingIssuesReferences

scripts/gh_identity.sh exec --need read "<owner>/<repository>#<issue-number>" -- \
  gh api graphql -f query='
    query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        issue(number:$number){
          projectItems(first:10){ nodes {
            id
            project{ number title }
            fieldValues(first:20){ nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name field { ... on ProjectV2SingleSelectField { name } } } } } } } }}}' \
  -F owner="<owner>" -F name="<repository>" -F number=<issue-number>
```

Record any field this identity cannot read as `unknown`, never as compliant.

## Lifecycle repair, one direction only

Per `references/policy/pr-lifecycle.md`, this package converts Ready back to Draft and moves a
ticket to `In Progress` or, after verified delivery, to `Done`. It contains no command that marks a pull
request ready, requests a reviewer, approves, merges, closes, or pushes, because the Reviewer performs
none of those. An explicitly read-only invocation runs neither of these and reports the repair instead.

```bash
scripts/gh_identity.sh exec --need write "<owner>/<repository>#<number>" -- \
  gh pr ready "<number>" --repo "<owner>/<repository>" --undo

scripts/gh_identity.sh exec --need write "<owner>/<repository>" -- \
  gh project item-edit --id "<item-id>" --project-id "<project-id>" \
  --field-id "<status-field-id>" --single-select-option-id "<option-id>"
```

Before `Done`, confirm delivery on the authoritative default branch rather than trusting the closed
state:

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh pr view "<number>" --repo "<owner>/<repository>" --json state,merged,mergeCommit,baseRefName
```

Project writes need a token carrying the project scope. When the verified identity lacks it, report the
item, the intended status, and the missing scope, and leave the write owed to a later cycle.

## Required checks

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>" -- \
  gh api "repos/<owner>/<repository>/branches/<base-branch>/protection" \
  --jq '.required_status_checks.contexts'

scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh api --paginate "repos/<owner>/<repository>/commits/<head-sha>/check-runs"
```

If the verified identity cannot read protection or ruleset data, record required-check status as
unknown and keep the code-happy gate closed.

## Isolated review checkout

```bash
lock=$(scripts/run_lock.sh acquire watch-and-review "<owner>-<repository>-pr<number>" \
  --meta '{"mode":"disposable-verification","artifact_globs":["^node_modules/","^\\.venv/","^target/","^dist/","^coverage/"]}')
run_id=$(printf '%s' "$lock" | jq -r '.run_id')
checkout=$(scripts/run_lock.sh path watch-and-review "<owner>" "<repository>" pr "<number>")

git -C "<managed-clone>" fetch --prune origin "pull/<number>/head"
scripts/run_lock.sh resource-acquire clone "watch-and-review-<owner>-<repository>" --run-id "$run_id"
git -C "<managed-clone>" worktree add --detach "$checkout" "<head-sha>"
scripts/run_lock.sh resource-release clone "watch-and-review-<owner>-<repository>" --run-id "$run_id"

git -C "$checkout" status --porcelain
```

Record status before each build or test command and compare afterwards. An unexplained path means the
checkout is retained, not removed.

## Snapshots

```bash
scripts/poll_pr.sh --once --cursor "<previous-cursor>" "<owner>/<repository>#<number>"
scripts/poll_pr.sh --once --cursor "<previous-cursor>" \
  --if-changed-since "<last-processed-fingerprint>" "<owner>/<repository>#<number>"
```

One snapshot is one cycle's read; this skill attaches no watcher, and running the next cycle is the
caller's decision.

Use the `--if-changed-since` form when the caller supplied a fingerprint: exit **3** with a one-line
`{"unchanged":true,...}` acknowledgement means the pull request has not moved and the cycle ends by
reporting exactly that; exit 0 delivers the full snapshot. A malformed fingerprint is refused before
any GitHub call.

A snapshot of kind `error` means the capture was incomplete: change nothing and do not advance the
cursor.

## Publish findings

Inline findings plus a summary, in one review:

```bash
scripts/gh_identity.sh exec --need write "<owner>/<repository>#<number>" -- \
  gh api --method POST "repos/<owner>/<repository>/pulls/<number>/reviews" \
  --field commit_id="<head-sha>" \
  --field event=REQUEST_CHANGES \
  --field body=@"<run-temp>/review-body.md" \
  --field 'comments[][path]=<path>' \
  --field 'comments[][line]=<line>' \
  --field 'comments[][side]=RIGHT' \
  --field 'comments[][body]=<finding>'
```

When the selected login authored the pull request, or the account cannot request changes, submit
`--field event=COMMENT` instead and state the limitation in the body. When a line position is stale,
drop the inline anchor and use a numbered finding with a `path:line` reference in the body.

## Reply in an existing thread

```bash
scripts/gh_identity.sh exec --need write "<owner>/<repository>#<number>" -- \
  gh api --method POST \
  "repos/<owner>/<repository>/pulls/<number>/comments/<in-reply-to-comment-id>/replies" \
  --field body=@"<run-temp>/reply.md"
```

## Resolve and unresolve a verified thread

Only for an eligible thread, only after independent verification on an unchanged tuple:

```bash
scripts/gh_identity.sh exec --need write "<owner>/<repository>#<number>" -- \
  gh api graphql -f query='
    mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread { id isResolved } } }' \
  -F id="<thread-id>"

scripts/gh_identity.sh exec --need write "<owner>/<repository>#<number>" -- \
  gh api graphql -f query='
    mutation($id:ID!){ unresolveReviewThread(input:{threadId:$id}){ thread { id isResolved } } }' \
  -F id="<thread-id>"
```

A human-authored thread receives a verification reply instead, unless the project sets
`resolve_human_threads` to `true`.

## Readiness

```bash
scripts/gh_identity.sh exec --need write "<owner>/<repository>#<number>" -- \
  gh pr comment "<number>" --repo "<owner>/<repository>" --body-file "<run-temp>/readiness.md"
```

Every body opens with:

```text
👀 From Reviewer: <exposed runtime label> · GitHub @<verified-login>
<!-- watch-and-review -->
```

## Cleanup

```bash
scripts/run_lock.sh remove watch-and-review "<owner>-<repository>-pr<number>" --run-id "$run_id"
scripts/run_lock.sh release watch-and-review "<owner>-<repository>-pr<number>" --state finished
```

If removal reports the checkout unsafe, release with `--state retained` and report exactly what was
retained and why.
