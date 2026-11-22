#!/usr/bin/env bash
# Test impact analysis, step 1 (playbook §75): which files did this push touch?
#
# Base of the diff:
#   - on the default branch: the commit before the push (github.event.before),
#     falling back to HEAD~1 for a new branch, a force push or a missing commit;
#   - on any other branch: the merge-base with origin/<default>, so every push to
#     a PR branch re-checks everything the branch changes, not only the last commit.
# Writes the changed-file list to $CHANGED_FILES and base/head/count to
# $GITHUB_OUTPUT. Needs a checkout with full history (fetch-depth: 0).
set -euo pipefail

default_branch=${DEFAULT_BRANCH:-main}
changed_file=${CHANGED_FILES:-${RUNNER_TEMP:-/tmp}/changed-files.txt}
zero=0000000000000000000000000000000000000000
head=$(git rev-parse HEAD)
base=""

if [ "${GITHUB_REF_NAME:-}" = "$default_branch" ]; then
  base=${BEFORE_SHA:-}
  if [ -z "$base" ] || [ "$base" = "$zero" ] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
    base=$(git rev-parse HEAD~1 2>/dev/null || true)
  fi
else
  git fetch --no-tags --quiet origin "$default_branch" 2>/dev/null || true
  base=$(git merge-base "origin/$default_branch" HEAD 2>/dev/null || git rev-parse HEAD~1 2>/dev/null || true)
fi

if [ -z "$base" ] || [ "$base" = "$head" ]; then
  # Nothing to compare with (first commit, or the branch is main's tip): check the last commit.
  base=$(git rev-parse HEAD~1 2>/dev/null || git hash-object -t tree /dev/null)
fi

git diff --name-only --no-renames "$base" "$head" > "$changed_file"
count=$(wc -l < "$changed_file" | tr -d ' ')

{
  echo "base=$base"
  echo "head=$head"
  echo "count=$count"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"

{
  echo "### Impact analysis"
  echo ""
  echo "Diff \`${base:0:12}..${head:0:12}\`: **$count** changed file(s)."
  echo ""
  echo "<details><summary>Changed files</summary>"
  echo ""
  echo '```'
  head -n 200 "$changed_file"
  [ "$count" -gt 200 ] && echo "… and $((count - 200)) more"
  echo '```'
  echo "</details>"
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
echo "Impact base $base, head $head, $count changed file(s)."
