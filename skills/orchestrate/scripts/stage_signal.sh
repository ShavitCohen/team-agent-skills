#!/usr/bin/env bash
# Classify one pull-request poll snapshot into the signals an orchestration acts on.
#
# The stage skills already publish everything an orchestrator needs — an automation
# marker and a literal status line — so reading them is pattern matching, not
# judgement, and it belongs in a script where it is deterministic and testable.
#
# A signal is ROUTING, NOT AUTHORITY. When a login is supplied and the event's author
# differs, the signal is kept and flagged unverified_actor rather than dropped: the
# orchestrator still needs to see that someone published a PASS, and it is the
# orchestrator — under the trust policy — that decides whether the actor is the stage
# it launched. This script never decides that, and never contacts GitHub.
set -euo pipefail

prog=${0##*/}
SCHEMA_VERSION=1

die() { printf '%s: %s\n' "$prog" "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

usage() {
  cat <<'EOF'
stage_signal.sh classify --file SNAPSHOT.json [--reviewer-login LOGIN]
                         [--developer-login LOGIN] [--qa-login LOGIN]

SNAPSHOT.json is one poll-snapshot-v1 document from poll_pr.sh.

Emits versioned JSON: the head SHA, the pull-request state and draft flag, and for
each family the newest matching event with its identifier, author, and creation
time —

  reviewer  pass | no_pass | code_happy_qa_pending
  qa        plan | result (with the parsed status and tested head, and whether that
            head matches the snapshot's current head)
  developer all_green

— plus the count of events carrying no family marker.

Detection is by the automation markers and the literal status lines the stage skills
publish. Supplying a login does not filter: a signal whose author differs is kept and
flagged unverified_actor. Malformed input exits non-zero.
EOF
}

classify() {
  local file=$1 reviewer=$2 developer=$3 qa=$4

  jq -e . "$file" >/dev/null 2>&1 || die "not valid JSON: $file"
  local version kind
  version=$(jq -r '.schema_version // empty' "$file")
  [ -n "$version" ] || die "snapshot has no schema_version: $file"
  case $version in ''|*[!0-9]*) die "snapshot schema_version is not a number: $version" ;; esac
  [ "$version" -le 1 ] || die "snapshot schema_version $version is newer than this script understands (1)"
  kind=$(jq -r '.kind // empty' "$file")
  [ -n "$kind" ] || die "snapshot has no kind: $file"
  if [ "$kind" != snapshot ]; then
    # An error or unchanged capture carries no events; say so rather than inventing
    # an empty snapshot's worth of "no signal" conclusions.
    jq -nc --argjson schema_version "$SCHEMA_VERSION" --arg kind "$kind" \
      '{schema_version:$schema_version, usable:false, kind:$kind,
        head_sha:null, pr_state:null, is_draft:null,
        reviewer:{}, qa:{}, developer:{}, unmarked_events:0}'
    return 0
  fi

  jq -c --argjson schema_version "$SCHEMA_VERSION" \
     --arg reviewer "$reviewer" --arg developer "$developer" --arg qa "$qa" '
    (.pull_request.head_sha // null) as $head
    | (.events // []) as $events

    # One event, reduced to what a signal needs.
    | def base($e): {id: ($e.id // null), author: ($e.author // null),
                     created_at: ($e.created_at // null), type: ($e.type // null)};
      def actor($e; $expected):
        if $expected == "" then null
        elif ($e.author // "") == $expected then true
        else false end;
      def newest($list): ($list | sort_by(.created_at // "") | last // null);

      ([$events[] | select((.body // "") | contains("<!-- watch-and-review -->"))]) as $rev
    | ([$events[] | select((.body // "") | contains("<!-- watch-and-fix -->"))]) as $dev
    | ([$events[] | select((.body // "") | contains("<!-- manual-qa:test-plan -->"))]) as $qaplan
    | ([$events[] | select((.body // "") | contains("<!-- manual-qa:test-results -->"))]) as $qares

    | (newest([$rev[] | select((.body // "") | contains("🟢 PASS — Ready for human review"))
               | base(.) + {unverified_actor: (actor(.; $reviewer) == false)}])) as $pass
    | (newest([$rev[] | select((.body // "") | contains("🔴 NO PASS"))
               | base(.) + {unverified_actor: (actor(.; $reviewer) == false)}])) as $no_pass
    | (newest([$rev[] | select((.body // "") | contains("🟢 Code-happy gate passed — 🔴 Manual QA required"))
               | base(.) + {unverified_actor: (actor(.; $reviewer) == false)}])) as $code_happy

    | (newest([$qaplan[] | base(.) + {unverified_actor: (actor(.; $qa) == false)}])) as $plan
    | (newest([$qares[]
               | . as $e
               | ($e.body // "") as $b
               | (($b | capture("Manual QA status:\\s*(?<s>PASS|FAIL|BLOCKED|STALE)") | .s)? // null) as $status
               | (($b | capture("(?<h>\\b[0-9a-f]{40}\\b)") | .h)? // null) as $tested
               | base($e) + {status: $status, tested_head: $tested,
                             matches_current_head: (if $tested == null or $head == null
                                                    then null else ($tested == $head) end),
                             unverified_actor: (actor($e; $qa) == false)}])) as $result

    | (newest([$dev[] | select((.body // "") | test("all green"; "i"))
               | base(.) + {unverified_actor: (actor(.; $developer) == false)}])) as $all_green

    | {schema_version: $schema_version,
       usable: true,
       kind: "snapshot",
       head_sha: $head,
       pr_state: (.pull_request.state // null),
       is_draft: (.pull_request.is_draft // null),
       reviewer: ({} + (if $pass then {pass: $pass} else {} end)
                     + (if $no_pass then {no_pass: $no_pass} else {} end)
                     + (if $code_happy then {code_happy_qa_pending: $code_happy} else {} end)),
       qa: ({} + (if $plan then {plan: $plan} else {} end)
               + (if $result then {result: $result} else {} end)),
       developer: ({} + (if $all_green then {all_green: $all_green} else {} end)),
       unmarked_events: ([$events[] | select(((.body // "") | contains("<!-- watch-and-review -->")) or
                                             ((.body // "") | contains("<!-- watch-and-fix -->")) or
                                             ((.body // "") | contains("<!-- manual-qa:test-plan -->")) or
                                             ((.body // "") | contains("<!-- manual-qa:test-results -->"))
                                             | not)] | length)}' "$file"
}

main() {
  need jq
  local action=${1:-}
  [ -n "$action" ] || { usage >&2; exit 2; }
  shift || true
  case $action in
    -h | --help) usage; return 0 ;;
    classify) : ;;
    *) die "unknown action: $action" ;;
  esac

  local file='' reviewer='' developer='' qa=''
  while [ $# -gt 0 ]; do
    case $1 in
      --file) file=${2:?--file needs a value}; shift 2 ;;
      --reviewer-login) reviewer=${2:?--reviewer-login needs a value}; shift 2 ;;
      --developer-login) developer=${2:?--developer-login needs a value}; shift 2 ;;
      --qa-login) qa=${2:?--qa-login needs a value}; shift 2 ;;
      *) die "unexpected option: $1" ;;
    esac
  done
  [ -n "$file" ] || die "--file is required"
  [ -f "$file" ] || die "no such snapshot: $file"
  classify "$file" "$reviewer" "$developer" "$qa"
}

main "$@"
