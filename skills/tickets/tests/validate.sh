#!/usr/bin/env bash
# Offline checks for the tickets package. No network and no token: every stage
# exercised here — filter parsing, search-query construction, and row shaping
# including status derivation and ordering — is pure.
set -uo pipefail

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
pkg=$(dirname -- "$here")
fixtures=$here/fixtures/queries.json
tickets=$pkg/scripts/fetch_tickets.sh

failures=0
fail() { failures=$(( failures + 1 )); printf '  FAIL  %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }

command -v jq >/dev/null 2>&1 || { printf 'validate.sh: jq is required\n' >&2; exit 2; }

# ------------------------------------------------------------------ structure

for f in SKILL.md references/output-format.md references/query-language.md \
         references/policy/trust.md scripts/fetch_tickets.sh tests/fixtures/queries.json; do
  [ -f "$pkg/$f" ] || fail "missing file: $f"
done
[ -x "$tickets" ] || fail "scripts/fetch_tickets.sh is not executable"
"$tickets" --help >/dev/null 2>&1 || fail "the script does not answer --help"

# The skill reports; it never writes to the tracker.
if grep -rIn -e 'gh issue edit' -e 'gh pr edit' -e 'gh issue close' -e 'gh pr comment' \
             -e 'gh issue comment' -e 'gh pr create' \
             "$pkg/SKILL.md" "$pkg/references" "$pkg/scripts" >/dev/null 2>&1; then
  fail "a tracker-mutating command is present in a read-only package"
else
  ok "the package contains no tracker-mutating command"
fi

# ---------------------------------------------------------------------- parse

n=$(jq '.parse | length' "$fixtures")
i=0; bad=0
while [ "$i" -lt "$n" ]; do
  name=$(jq -r ".parse[$i].name" "$fixtures")
  request=$(jq -r ".parse[$i].request" "$fixtures")
  expect=$(jq -Sc ".parse[$i].expect" "$fixtures")
  got=$("$tickets" parse $request 2>/dev/null \
        | jq -Sc '{state,sprints,priorities,repos,labels,blockedOnly,epics,assignee,unparsed}')
  if [ "$got" != "$expect" ]; then
    fail "parse: $name"
    printf '          want %s\n          got  %s\n' "$expect" "$got"
    bad=1
  fi
  i=$(( i + 1 ))
done
[ "$bad" = 0 ] && ok "all $n free-text requests parse to the specified filter"

# ---------------------------------------------------------------------- query

n=$(jq '.query | length' "$fixtures")
i=0; bad=0
while [ "$i" -lt "$n" ]; do
  request=$(jq -r ".query[$i].request" "$fixtures")
  login=$(jq -r ".query[$i].login" "$fixtures")
  expect=$(jq -r ".query[$i].expect" "$fixtures")
  got=$("$tickets" parse $request 2>/dev/null | "$tickets" query --login "$login" 2>/dev/null)
  if [ "$got" != "$expect" ]; then
    fail "query: '$request'"
    printf '          want %s\n          got  %s\n' "$expect" "$got"
    bad=1
  fi
  i=$(( i + 1 ))
done
[ "$bad" = 0 ] && ok "all $n filters build the specified search query"

# ---------------------------------------------------------------------- shape

shaped=$(jq -c '.shape.nodes' "$fixtures" | "$tickets" shape 2>/dev/null)
if [ -z "$shaped" ]; then
  fail "shape produced no output"
else
  want=$(jq -c '.shape.expectOrder' "$fixtures")
  got=$(printf '%s' "$shaped" | jq -c '[.[].number]')
  if [ "$want" = "$got" ]; then
    ok "rows sort by priority, then by how much the row wants attention"
  else
    fail "shape: row order"
    printf '          want %s\n          got  %s\n' "$want" "$got"
  fi

  bad=0
  while IFS= read -r number; do
    [ -n "$number" ] || continue
    expect=$(jq -Sc --arg n "$number" '.shape.expectRows[$n]' "$fixtures")
    got=$(printf '%s' "$shaped" | jq -Sc --argjson n "$number" --argjson e "$expect" '
      map(select(.number == $n)) | first
      | { status, priority, sprint, isEpic, prCell: .prCell.text,
          link: (.pr.link // null), statusHref,
          blockedBy: [.blockedBy[].number], blockedByClosed }
      | with_entries(select(.key | in($e)))')
    if [ "$got" != "$expect" ]; then
      fail "shape: ticket $number"
      printf '          want %s\n          got  %s\n' "$expect" "$got"
      bad=1
    fi
  done < <(jq -r '.shape.expectRows | keys[]' "$fixtures")
  [ "$bad" = 0 ] && ok "every fixture ticket derives the specified status, link, and cells"

  # A pull request that only mentioned a ticket from another repository is not
  # that ticket's pull request, and must never reach the column.
  if [ "$(printf '%s' "$shaped" | jq '[.[] | select(.number == 105) | .pr] | first')" = "null" ]; then
    ok "a foreign mention never fills the pull-request column"
  else
    fail "a foreign cross-reference was accepted as the ticket's pull request"
  fi

  # The regression this package exists to prevent. Ticket 104 is cross-referenced
  # by an open pull request in its own repository whose title and branch name it
  # nowhere. Accepting that mention is what once reported one merged pull request
  # as the work of three unrelated tickets.
  if [ "$(printf '%s' "$shaped" | jq '[.[] | select(.number == 104) | .pr] | first')" = "null" ]; then
    ok "a same-repository mention never fills the pull-request column"
  else
    fail "a same-repository cross-reference was accepted as the ticket's pull request"
  fi

  # The branch convention joins on the ticket the branch actually names. A branch
  # for 1234 is not evidence about ticket 34.
  if [ "$(printf '%s' "$shaped" | jq '[.[] | select(.number == 34) | .pr] | first')" = "null" ]; then
    ok "a branch naming a different ticket never joins"
  else
    fail "a branch whose leading number is not this ticket was accepted as evidence"
  fi

  # No cell may carry an uncertainty marker: a marked guess still reads as a report.
  if [ "$(printf '%s' "$shaped" | jq '[.[] | select(.prCell.text | test("\\?"))] | length')" = 0 ]; then
    ok "no pull-request cell carries an uncertainty marker"
  else
    fail "a pull-request cell still renders a guess marker"
  fi

  # A ticket can only see the check rollup, and the rollup calls a cancelled or
  # skipped job a failure. Ticket rows therefore never speak about checks.
  if [ "$(printf '%s' "$shaped" | jq '[.[] | select(.status | test("check"; "i"))] | length')" = 0 ]; then
    ok "no ticket row reports check state"
  else
    fail "a ticket row derived a status from the check rollup"
  fi
fi

# ------------------------------------------------------------------ shape-prs

shapedPrs=$(jq -c '.shapePrs.nodes' "$fixtures" | "$tickets" shape-prs 2>/dev/null)
if [ -z "$shapedPrs" ]; then
  fail "shape-prs produced no output"
else
  want=$(jq -c '.shapePrs.expectOrder' "$fixtures")
  got=$(printf '%s' "$shapedPrs" | jq -c '[.[].number]')
  if [ "$want" = "$got" ]; then
    ok "pull requests sort ready-to-merge, then owed by you, then waiting on others"
  else
    fail "shape-prs: row order"
    printf '          want %s\n          got  %s\n' "$want" "$got"
  fi

  bad=0
  while IFS= read -r number; do
    [ -n "$number" ] || continue
    expect=$(jq -Sc --arg n "$number" '.shapePrs.expectRows[$n]' "$fixtures")
    got=$(printf '%s' "$shapedPrs" | jq -Sc --argjson n "$number" --argjson e "$expect" '
      map(select(.number == $n)) | first
      | { owner, nextMove, detail, unresolvedThreads,
          failing: .checks.failing, running: .checks.running,
          claims: [ .claims[] | { number, via } ] }
      | with_entries(select(.key | in($e)))')
    if [ "$got" != "$expect" ]; then
      fail "shape-prs: pull request $number"
      printf '          want %s\n          got  %s\n' "$expect" "$got"
      bad=1
    fi
  done < <(jq -r '.shapePrs.expectRows | keys[]' "$fixtures")
  [ "$bad" = 0 ] && ok "every fixture pull request derives the specified next move and detail"

  # Pull request 502 carries a FAILURE rollup over one real failure, one skipped
  # job and one cancelled job. Only the real failure is work its author owes, and
  # it is named rather than counted.
  failing=$(printf '%s' "$shapedPrs" | jq -c '[.[] | select(.number == 502) | .checks.failing] | first')
  if [ "$failing" = '["plan"]' ]; then
    ok "a cancelled or skipped check is never reported as failing, and a real one is named"
  else
    fail "check classification read the rollup instead of the named contexts: $failing"
  fi
fi

# ------------------------------------------------------------------- reporting

if [ "$failures" = 0 ]; then
  printf 'tickets: all offline checks passed\n'
else
  printf 'tickets: %d offline check(s) failed\n' "$failures"
  exit 1
fi
