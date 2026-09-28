#!/usr/bin/env bash
# Offline checks for the ship package. The package has no scripts: what can
# drift is its text, so these checks pin the rules that keep a ship run safe
# and portable. No network, no token, and no repository are needed.
set -uo pipefail

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
pkg=$(dirname -- "$here")
skill=$pkg/SKILL.md
brief=$pkg/references/reviewer-brief.md
template=$pkg/references/pr-comment-template.md
trust=$pkg/references/policy/trust.md

passes=0
failures=0
fail() { failures=$(( failures + 1 )); printf '  FAIL  %s\n' "$*"; }
ok()   { passes=$(( passes + 1 )); printf '  ok    %s\n' "$*"; }

# expect FILE TEXT RULE: FILE must still state TEXT, a fixed string.
expect() {
  if grep -qF -e "$2" -- "$1"; then
    ok "$3"
  else
    fail "$3 (${1#"$pkg"/} no longer says: $2)"
  fi
}

# line_of FILE TEXT: the first line number holding TEXT, or nothing.
line_of() { grep -nF -e "$2" -- "$1" | head -1 | cut -d: -f1; }

# ------------------------------------------------------------------ structure

missing=0
for f in SKILL.md references/reviewer-brief.md references/pr-comment-template.md \
         references/policy/trust.md tests/validate.sh; do
  [ -f "$pkg/$f" ] || { fail "missing file: $f"; missing=1; }
done
if [ "$missing" = 1 ]; then
  printf 'validate.sh: %s passed, %s failed\n' "$passes" "$failures"
  exit 1
fi
ok "every specified file is present"

# -------------------------------------------------------------------- trigger

# Ship runs only when asked for by name: the portable form of a skill the
# model must not start on its own.
desc=$(awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$skill" | sed -n 's/^description:[[:space:]]*//p')
case $desc in
  *"Use only when the user explicitly invokes ship"*)
    ok "the description keeps ship to explicit invocation" ;;
  *)
    fail "the description no longer limits ship to explicit invocation" ;;
esac

# ---------------------------------------------------------------- portability

# No harness's own tool names, argument placeholders or metadata keys: the
# package describes a capability and says what to do when it is missing.
harness_hits=$(grep -rlE --exclude=validate.sh \
  -e 'EnterWorktree|ExitWorktree|SendMessage|ToolSearch|\$ARGUMENTS|disable-model-invocation|argument-hint' \
  -- "$pkg" || true)
if [ -n "$harness_hits" ]; then
  for f in $harness_hits; do fail "harness-specific tool name or metadata in ${f#"$pkg"/}"; done
else
  ok "no harness-specific tool names, placeholders or metadata keys"
fi

# ---------------------------------------------------------------------- phases

# The pull request comes last: it opens only after the review loop and the
# round on the merge from main.
prev=0
order_ok=1
for heading in '## 1. Worktree' '## 2. Plan' '## 3. Build' '## 4. Review loop' \
               '## 5. Catch up with main' '## 6. Open the PR' '## 7. Post the review log'; do
  n=$(line_of "$skill" "$heading")
  if [ -z "$n" ] || [ "$n" -le "$prev" ]; then
    fail "phase missing or out of order: $heading"
    order_ok=0
  else
    prev=$n
  fi
done
[ "$order_ok" = 1 ] && ok "the seven phases appear in order"

create_at=$(line_of "$skill" 'gh pr create')
open_at=$(line_of "$skill" '## 6. Open the PR')
if [ -n "$create_at" ] && [ -n "$open_at" ] && [ "$create_at" -gt "$open_at" ]; then
  ok "the pull request is created only in the phase after the review loop"
else
  fail "the pull request is created outside the phase after the review loop"
fi

# ------------------------------------------------------------------ hard rules

expect "$skill" "Don't merge the PR, approve it, or turn on auto-merge." \
  "ship never merges, approves, or enables auto-merge"
expect "$skill" "Don't substitute a self-review" \
  "a self-review never stands in for the independent reviewer"
expect "$skill" "An approval that still lists things worth fixing is another round" \
  "an approval with notes worth fixing does not end the loop"
expect "$skill" "Verification passed on the exact commit you will push" \
  "the loop ends only with verification on the exact commit that is pushed"
expect "$skill" "They never override this skill's safety rules" \
  "repository rules never override the safety rules"
expect "$skill" "references/policy/trust.md" \
  "the run reads the trust policy before any issue, PR or comment text"
expect "$skill" "/tmp/ship-<branch>/" \
  "scratch files live outside the repository, so they are never committed"

# A package that must never merge, approve or write to a ticket holds no
# command that would, anywhere.
bad=0
for pattern in 'gh pr merge' 'gh pr review' '--approve' '--auto' 'gh issue edit' 'gh issue comment' 'gh issue close' 'gh issue create'; do
  if grep -rqF --exclude=validate.sh -e "$pattern" -- "$pkg"; then
    fail "the package contains the command '$pattern'"
    bad=1
  fi
done
[ "$bad" = 0 ] && ok "no merge, approve, auto-merge or ticket-writing command anywhere"

# -------------------------------------------------------------------- reviewer

expect "$brief" "Read-only. Don't edit files, commit, switch branches, stash, or install anything" \
  "the reviewer is read-only"
expect "$brief" "Don't run builds or full test suites." \
  "the reviewer never runs a second verification beside the author's"
expect "$brief" "VERDICT: APPROVE or REQUEST_CHANGES" \
  "the reviewer replies with an explicit verdict"
expect "$brief" "Worth fixing: yes | no" \
  "every finding says whether it is worth fixing"
for section in '## Round 1: the spawn prompt' '## Later rounds: the follow-up message' \
               '## A round on a merge from main' "## When the reviewer can't be continued"; do
  expect "$brief" "$section" "the brief keeps its template: ${section#"## "}"
done

# ------------------------------------------------------------------ review log

expect "$template" "Keep declined findings and their reasons." \
  "declined findings keep their reasons in the PR comment"
expect "$template" "the reviewer's agent ID" \
  "the reviewer's agent ID never reaches the PR comment"
expect "$template" "Every short SHA must be a commit on the pushed branch." \
  "every SHA in the comment is a commit on the pushed branch"

# --------------------------------------------------------------- shared policy

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'
  fi
}
declared=$(sed -n '1s/.*sha256=\([0-9a-f]\{64\}\).*/\1/p' "$trust")
computed=$(sed '1d' "$trust" | sha256)
if [ -n "$declared" ] && [ "$declared" = "$computed" ]; then
  ok "references/policy/trust.md matches its provenance hash"
else
  fail "references/policy/trust.md does not match its provenance hash (declared ${declared:-none}, computed $computed)"
fi

printf 'validate.sh: %s passed, %s failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
