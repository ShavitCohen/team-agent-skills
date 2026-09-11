# Reference commands

Every GitHub call goes through `scripts/gh_identity.sh`, which supplies one account's credentials for
that command only. Placeholders are written `<like-this>`; nothing here hardcodes a login, a home
directory, or a repository.

## Parse the target

```text
https://github.com/OWNER/REPOSITORY/issues/NUMBER  ->  owner, repository, number
```

Reject any other shape rather than guessing at it.

## Select an identity

```bash
scripts/gh_identity.sh select --need read "<owner>/<repository>#<number>"
scripts/gh_identity.sh select --need write "<owner>/<repository>"
```

## Read the ticket and its references

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh api "repos/<owner>/<repository>/issues/<number>"

scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh api --paginate "repos/<owner>/<repository>/issues/<number>/comments"

scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh api --paginate "repos/<owner>/<repository>/issues/<number>/timeline" \
  -H "Accept: application/vnd.github+json"
```

## Resolve the default branch

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>" -- \
  gh api "repos/<owner>/<repository>" --jq '.default_branch'
```

## Post the Clarifications comment, idempotently

Check for this skill's marker first, and post only if it is absent for the current round:

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh api --paginate "repos/<owner>/<repository>/issues/<number>/comments" \
  --jq '.[] | select(.body | contains("<!-- implement -->")) | {id, html_url, created_at}'

scripts/gh_identity.sh exec --need comment "<owner>/<repository>#<number>" -- \
  gh issue comment "<number>" --repo "<owner>/<repository>" --body-file "<run-temp>/clarifications.md"
```

Record the returned URL and identifier. A later round posts a **new** comment; it never edits an
earlier one, and it never writes the issue body, title, labels, milestone, or assignees.

## Detect an existing implementation pull request

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>" -- \
  gh pr list --repo "<owner>/<repository>" --state open --json number,headRefName,url,author \
  --search "<number> in:body"
```

If one governs this ticket, stop and hand it to **watch-and-fix** rather than creating a duplicate.

## Fork detection, only when the base repository cannot be pushed to

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>" -- \
  gh api "repos/<owner>/<repository>" --jq '.permissions'

scripts/gh_identity.sh exec --need read "<owner>/<repository>" -- \
  gh api "user/repos?type=owner&per_page=100" --paginate \
  --jq '.[] | select(.fork and .parent_full_name == "<owner>/<repository>") | .full_name'
```

Reuse an existing user-owned fork. Ask before creating one, and never create a second.

## Managed clone and worktree

```bash
lock=$(scripts/run_lock.sh acquire implement "<owner>-<repository>-issue<number>" \
  --meta '{"mode":"editable","target":{"owner":"<owner>","repository":"<repository>","kind":"issue","number":<number>}}')
run_id=$(printf '%s' "$lock" | jq -r '.run_id')
worktree=$(scripts/run_lock.sh path implement "<owner>" "<repository>" issue "<number>")

git -C "<managed-clone>" fetch --prune origin
scripts/run_lock.sh resource-acquire clone "implement-<owner>-<repository>" --run-id "$run_id"
git -C "<managed-clone>" worktree add -b "<branch>" "$worktree" "origin/<default-branch>"
scripts/run_lock.sh resource-release clone "implement-<owner>-<repository>" --run-id "$run_id"

scripts/run_lock.sh acquire implement "<owner>-<repository>-issue<number>" \
  --meta "$(jq -nc --arg w "$worktree" --arg b "<branch>" --arg c "<managed-clone>" \
    '{worktree:$w, branch:$b, clone:$c, mode:"editable"}')"
```

Inspect before reusing an existing worktree; never remove or reset it:

```bash
git -C "$worktree" status --porcelain
git -C "$worktree" log --oneline "origin/<default-branch>..HEAD"
```

## Push with credentials scoped to one command

```bash
scripts/gh_identity.sh git-push "<owner>/<repository>#<number>" \
  --repo "<head-owner>/<head-repository>" \
  --remote-url "https://github.com/<head-owner>/<head-repository>.git" \
  --source HEAD --dest "refs/heads/<branch>"
```

Add `--force-with-lease <full-sha>` only when repository policy permits a force push to this branch and
the exact previously observed remote SHA is known. A lease mismatch means someone else pushed: re-fetch
and rebuild the change rather than forcing over it.

## Open the pull request as a draft, at most once

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>" -- \
  gh pr list --repo "<owner>/<repository>" --head "<head-owner>:<branch>" --state all --json number,url

scripts/gh_identity.sh exec --need write "<owner>/<repository>" -- \
  gh pr create --draft --repo "<owner>/<repository>" --base "<default-branch>" \
  --head "<head-owner>:<branch>" --title "<title>" --body-file "<run-temp>/pr-body.md"
```

### Pull-request body template

```markdown
🛠 From Developer: <exposed runtime label> · GitHub @<verified-login>
<!-- implement -->

## Summary
<what changed and why, in the ticket's terms>

## Verification
<the tests actually run and their real output; browser check result or "not performed" with the reason>

## What was not checked
<untested paths, unverified assumptions, deferred items, residual risks>

## Out of scope, noticed and not fixed
<in-scope-adjacent issues seen during the work>

Closes #<number>
```

Nothing in this package merges the pull request, enables automatic merging, or submits an approving
review.

## Mark it ready and request the named human reviewer, as one operation

Run these two calls back to back, per `references/policy/pr-lifecycle.md`. Nothing goes between them.

```bash
scripts/gh_identity.sh exec --need write "<owner>/<repository>#<pr-number>" -- \
  gh pr ready "<pr-number>" --repo "<owner>/<repository>"

scripts/gh_identity.sh exec --need write "<owner>/<repository>#<pr-number>" -- \
  gh api --method POST "repos/<owner>/<repository>/pulls/<pr-number>/requested_reviewers" \
  -f 'reviewers[]=<human-login>'
```

If the reviewer request fails, put the pull request back in draft rather than leaving it ready and
unassigned:

```bash
scripts/gh_identity.sh exec --need write "<owner>/<repository>#<pr-number>" -- \
  gh pr ready "<pr-number>" --repo "<owner>/<repository>" --undo
```

`gh pr edit --add-reviewer` reaches the same result, but it fails on repositories whose metadata the
CLI cannot render; the REST call above does not.

## Move the ticket's board item

Read the ticket's project items, its status field, and that field's options:

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
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
  -F owner="<owner>" -F name="<repository>" -F number=<number>

scripts/gh_identity.sh exec --need read "<owner>/<repository>" -- \
  gh project field-list "<project-number>" --owner "<owner>" --format json
```

Then set the status to the option matching the canonical name:

```bash
scripts/gh_identity.sh exec --need write "<owner>/<repository>" -- \
  gh project item-edit --id "<item-id>" --project-id "<project-id>" \
  --field-id "<status-field-id>" --single-select-option-id "<option-id>"
```

Project writes need a token carrying the project scope. When the verified identity lacks it, report the
item, the intended status, and the missing scope, and continue — the pull-request half of the invariant
still stands on its own.

## Verify the lifecycle invariant before reporting

```bash
scripts/gh_identity.sh exec --need read "<owner>/<repository>#<number>" -- \
  gh pr view "<pr-number>" --repo "<owner>/<repository>" \
  --json isDraft,state,reviewRequests,reviewDecision,url,closingIssuesReferences
```
