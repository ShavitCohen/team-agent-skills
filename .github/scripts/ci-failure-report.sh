#!/usr/bin/env bash
# shellcheck disable=SC2016  # backticks in printf formats are Markdown, not shell
# Failure analysis for one CI test group (playbook §75).
# Usage: ci-failure-report.sh GROUP LOGFILE
# Writes a short report (failing tests, likely cause, log excerpt) to the job's
# step summary and to the step output `report`, which the workflow's summary job
# shows. Only reads the log the group's own command printed; no environment dump.
set -uo pipefail

group=${1:?group}
log=${2:?logfile}
slug=$(printf %s "$group" | tr -c "A-Za-z0-9_-" "_")
out=${RUNNER_TEMP:-/tmp}/failure-report-$slug.md

if [ ! -s "$log" ]; then
  printf 'Group **%s** failed before writing a log (install or setup step). See the job log.\n' "$group" > "$out"
else
  clean=${RUNNER_TEMP:-/tmp}/failure-log-$slug.txt
  # Strip ANSI colours so the patterns below match.
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" > "$clean"

  failing=$(grep -E '^[[:space:]]*(FAIL|×|✗|✕|❯ .*\([0-9]+ tests? \| [0-9]+ failed)' "$clean" \
    | sed -E 's/^[[:space:]]+//' | awk '!seen[$0]++' | head -n 30)
  lint=$(grep -E '^[[:space:]]+[0-9]+:[0-9]+[[:space:]]+error[[:space:]]|error TS[0-9]+|^\S+\([0-9]+,[0-9]+\): error' "$clean" | head -n 20)
  [ -z "$failing" ] && failing=$lint
  [ -z "$failing" ] && failing=$(grep -E -i '(^|[^a-z])(error|failed|failure)([^a-z]|$)' "$clean" | awk '!seen[$0]++' | head -n 15)

  cause="Unclassified failure: read the excerpt and the job log."
  if grep -Eq 'Test timed out|Hook timed out|timed out in [0-9]+ms|Timeout waiting for worker' "$clean"; then
    cause="Timeout: a test or hook ran past its limit (slow code, an unawaited promise, or a hung service). Re-run that file alone before treating it as a regression."
  elif grep -Eq 'AssertionError|Expected:|expected .* to (be|equal|have|match|contain)|toMatchSnapshot|Snapshot .* mismatched' "$clean"; then
    cause="Assertion failure: the code no longer does what the test expects. Check the diff against the failing test first."
  elif grep -Eq 'error TS[0-9]+|Type error:|is not assignable to' "$clean"; then
    cause="Type error: TypeScript rejects the change (see the TS lines above)."
  elif grep -Eq '[0-9]+:[0-9]+[[:space:]]+error[[:space:]]|✖ [0-9]+ problems?' "$clean"; then
    cause="Lint error: ESLint or a repo guard rejected the change (see the file:line entries above)."
  elif grep -Eq 'Cannot find module|Failed to resolve import|ERR_MODULE_NOT_FOUND|Module not found' "$clean"; then
    cause="Import error: a module or path can't be resolved (renamed or deleted file, or a missing dependency)."
  elif grep -Eq 'ECONNREFUSED|MongoServerSelectionError|MongoNetworkError|PoolCleared|mongod|MongoMemoryServer' "$clean"; then
    cause="Database/service error: the test database or another service wasn't reachable. Likely environment, check before changing code."
  elif grep -Eq 'frozen-lockfile|Your lockfile needs to be updated|ERR_PNPM|npm ERR!|error An unexpected error occurred' "$clean"; then
    cause="Dependency install error: the lockfile is out of date or the registry failed."
  elif grep -Eq 'ENOSPC|out of memory|JavaScript heap out of memory|Killed' "$clean"; then
    cause="Runner resources: out of memory or disk. Not a test verdict."
  fi

  {
    printf '#### Group `%s` failed\n\n' "$group"
    printf '**Likely cause:** %s\n\n' "$cause"
    if [ -n "$failing" ]; then
      printf '**Failing tests / errors:**\n```\n%s\n```\n\n' "$failing"
    fi
    printf '<details><summary>Last 40 log lines</summary>\n\n```\n'
    tail -n 40 "$clean"
    printf '```\n</details>\n'
  } > "$out"
fi

# Job outputs are size-limited: keep the report short.
report=$(head -c 12000 "$out")
cat "$out" >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  delim="REPORT_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  {
    echo "report<<$delim"
    printf '%s\n' "$report"
    echo "$delim"
  } >> "$GITHUB_OUTPUT"
fi
exit 0
