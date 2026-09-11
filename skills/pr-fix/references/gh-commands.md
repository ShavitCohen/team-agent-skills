# Reference commands

Every GitHub call goes through `scripts/gh_identity.sh`. Placeholders are written `<like-this>`;
nothing here hardcodes a login, a home directory, or a repository. This file contains no
thread-resolution command and no merge command, because the Developer performs neither.

## Parse the target

```text
https://github.com/OWNER/REPOSITORY/pull/NUMBER   ->  owner, repository, number
OWNER/REPOSITORY#NUMBER                           ->  owner, repository, number
```

## Select an identity

```bash
scripts/gh_identity.sh select --need read "<owner>/<repository>#<number>"
scripts/gh_identity.sh select --need comment "<owner>/<repository>#<number>"
scripts/gh_identity.sh select --need push "<owner>/<repository>"
```

## Snapshot the pull request

```bash
scripts/poll_pr.sh --once --cursor "<previous-cursor>" "<owner>/<repository>#<number>"
scripts/poll_pr.sh --once --cursor "<previous-cursor>" \
  --if-changed-since "<last-processed-fingerprint>" "<owner>/<repository>#<number>"
```

A cycle takes exactly one snapshot and schedules no cadence of its own; the caller decides when the
next cycle runs.

When the caller supplied a fingerprint, use the `--if-changed-since` form: exit **3** with a one-line
`{"unchanged":true,...}` acknowledgement means the pull request has not moved — report that and end the
cycle; exit 0 delivers the full snapshot. A malformed fingerprint is refused before any GitHub call.

A snapshot of kind `error` means the capture was incomplete: act on nothing and do not advance the
cursor.

## Read the pull request and its linked tickets

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh api "repos/<owner>/<repository>/pulls/<number>"

scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh api graphql -f query='
    query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        pullRequest(number:$number){
          closingIssuesReferences(first:20){ nodes { number url title body } }
        }}}' -F owner="<owner>" -F name="<repository>" -F number=<number>
```

## Mergeability, review decision, and checks

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh pr view "<number>" --repo "<owner>/<repository>" \
  --json mergeable,mergeStateStatus,reviewDecision,headRefOid,baseRefName,isDraft,state

scripts/gh_identity.sh exec --need read "<owner>/<repository>" -- \
  gh api "repos/<owner>/<repository>/branches/<base-branch>/protection" \
  --jq '.required_status_checks.contexts'
```

If the required-check set cannot be determined with the verified identity, record it as unknown rather
than assuming the visible checks are the required ones.

## Paginated reviews, threads, and comments

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh api --paginate "repos/<owner>/<repository>/pulls/<number>/reviews"

scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh api --paginate "repos/<owner>/<repository>/issues/<number>/comments"
```

Review threads and their identifiers come from the snapshot, which paginates them for you.

## Reply in a thread

```bash
scripts/gh_identity.sh exec --need comment "<owner>/<repository>#<number>" -- \
  gh api --method POST \
  "repos/<owner>/<repository>/pulls/<number>/comments/<in-reply-to-comment-id>/replies" \
  --field body=@"<run-temp>/reply.md"
```

## Post a top-level comment

```bash
scripts/gh_identity.sh exec --need comment "<owner>/<repository>#<number>" -- \
  gh pr comment "<number>" --repo "<owner>/<repository>" --body-file "<run-temp>/status.md"
```

Every body opens with:

```text
🛠 From Developer: <exposed runtime label> · GitHub @<verified-login>
<!-- watch-and-fix -->
```

## Lifecycle: draft state, reviewer, and board

Mark ready and request the named human reviewer back to back, with nothing between them, per
`references/policy/pr-lifecycle.md`:

```bash
scripts/gh_identity.sh exec --need write "<owner>/<repository>#<number>" -- \
  gh pr ready "<number>" --repo "<owner>/<repository>"

scripts/gh_identity.sh exec --need write "<owner>/<repository>#<number>" -- \
  gh api --method POST "repos/<owner>/<repository>/pulls/<number>/requested_reviewers" \
  -f 'reviewers[]=<human-login>'
```

Return it to draft while author work remains, or when the reviewer request failed:

```bash
scripts/gh_identity.sh exec --need write "<owner>/<repository>#<number>" -- \
  gh pr ready "<number>" --repo "<owner>/<repository>" --undo
```

`gh pr edit --add-reviewer` reaches the same result, but it fails on repositories whose metadata the
CLI cannot render; the REST call above does not.

Read the linked ticket's project item, its status field, and that field's options, then set the status:

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>#<issue-number>" -- \
  gh api graphql -f query='
    query($owner:String!,$name:String!,$number:Int!){
      repository(owner:$owner,name:$name){
        issue(number:$number){
          projectItems(first:10){ nodes {
            id
            project{ id number title }
            fieldValues(first:20){ nodes {
              ... on ProjectV2ItemFieldSingleSelectValue {
                name optionId field { ... on ProjectV2SingleSelectField { id name } } } } } } } }}}' \
  -F owner="<owner>" -F name="<repository>" -F number=<issue-number>

scripts/gh_identity.sh exec --need read "<owner>/<repository>" -- \
  gh project field-list "<project-number>" --owner "<owner>" --format json

scripts/gh_identity.sh exec --need write "<owner>/<repository>" -- \
  gh project item-edit --id "<item-id>" --project-id "<project-id>" \
  --field-id "<status-field-id>" --single-select-option-id "<option-id>"
```

Project writes need a token carrying the project scope. When the verified identity lacks it, report the
item, the intended status, and the missing scope, and keep watching.

Verify the invariant before reporting all green:

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh pr view "<number>" --repo "<owner>/<repository>" \
  --json isDraft,state,reviewRequests,reviewDecision,url,closingIssuesReferences
```

## Managed clone and worktree

```bash
lock=$(scripts/run_lock.sh acquire watch-and-fix "<owner>-<repository>-pr<number>" \
  --meta '{"mode":"editable"}')
run_id=$(printf '%s' "$lock" | jq -r '.run_id')
worktree=$(scripts/run_lock.sh path watch-and-fix "<owner>" "<repository>" pr "<number>")

git -C "<managed-clone>" fetch --prune origin
scripts/run_lock.sh resource-acquire clone "watch-and-fix-<owner>-<repository>" --run-id "$run_id"
git -C "<managed-clone>" worktree add "$worktree" "origin/<head-branch>"
scripts/run_lock.sh resource-release clone "watch-and-fix-<owner>-<repository>" --run-id "$run_id"
```

Before **every** edit:

```bash
git -C "$worktree" fetch origin "<head-branch>"
git -C "$worktree" status --porcelain
git -C "$worktree" merge --ff-only "origin/<head-branch>"
```

## Base synchronization, by repository policy

Update through GitHub when the repository prefers a merge:

```bash
scripts/gh_identity.sh exec --need push "<owner>/<repository>#<number>" -- \
  gh api --method PUT "repos/<owner>/<repository>/pulls/<number>/update-branch"
```

Or merge the base locally:

```bash
git -C "$worktree" fetch origin "<base-branch>"
git -C "$worktree" merge "origin/<base-branch>"
```

Rebase only when repository policy allows a force push to this head branch, the branch is not shared,
and no semantic conflict exists:

```bash
git -C "$worktree" rebase "origin/<base-branch>"
```

## Push

```bash
scripts/gh_identity.sh git-push "<owner>/<repository>#<number>" \
  --repo "<head-owner>/<head-repository>" \
  --remote-url "https://github.com/<head-owner>/<head-repository>.git" \
  --source HEAD --dest "refs/heads/<head-branch>"
```

After a rebase, add `--force-with-lease <full-sha-observed-before-the-rebase>`. A rejected lease means
someone else pushed: re-fetch and rebuild the fix.

## Long-running commands

```bash
scripts/run_lock.sh with watch-and-fix "<owner>-<repository>-pr<number>" -- <the repository's test command>
```

## Cleanup

```bash
scripts/run_lock.sh remove watch-and-fix "<owner>-<repository>-pr<number>" --run-id "$run_id"
scripts/run_lock.sh release watch-and-fix "<owner>-<repository>-pr<number>" --state finished
```

If removal reports the worktree unsafe, release with `--state retained` instead and tell the user
exactly what is unsaved and where.
