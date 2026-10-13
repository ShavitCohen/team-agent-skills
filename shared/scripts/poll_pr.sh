#!/usr/bin/env bash
# shared-component: poll_pr.sh v3 sha256=bf732d636cbaf2660ba571231ed9f50685e7f6105464e5ffdb4463c1026f056a
# Capture versioned, fully paginated pull-request snapshots for a watcher loop.
# Every GitHub call is routed through gh_identity.sh. An incomplete capture emits an
# error snapshot and never advances the continuation cursor. Change detection happens
# here, not in the model: a capture that carries nothing new is never delivered, so a
# watching agent is activated only by real movement on the pull request.
set -euo pipefail

prog=${0##*/}
SCHEMA_VERSION=1
MIN_INTERVAL=120
EXIT_UNCHANGED=3

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
identity="$script_dir/gh_identity.sh"

die() { printf '%s: %s\n' "$prog" "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
whole_number() { printf '%s' "$1" | LC_ALL=C grep -qE '^[0-9]+$'; }

usage() {
  cat <<'EOF'
poll_pr.sh --once  [--user LOGIN] [--cursor CURSOR] [--if-changed-since FINGERPRINT] TARGET
poll_pr.sh --watch [--user LOGIN] [--cursor CURSOR] [--interval SECONDS]
                   [--if-changed-since FINGERPRINT] TARGET

TARGET is a pull-request URL or OWNER/REPOSITORY#NUMBER.

Watch mode captures every --interval seconds (120 by default, and refused below
120). Cadence is measured capture-start to capture-start, so the snapshot's own
duration is subtracted from the next wait rather than added to the interval.

Every complete snapshot carries a fingerprint: a digest over every change-relevant
field — the whole snapshot except its capture time. It covers the normalized
pull-request metadata, the checks, the FULL paginated comment, review, thread, and
reply collections, and the unresolved-thread set, and excludes the capture time,
the capture duration, and the cursor. Equal fingerprints mean nothing observable
changed on the pull request.

--if-changed-since takes a fingerprint from a previous snapshot, in the form
sha256: followed by 64 lowercase hexadecimal characters. A malformed value is
refused before any GitHub call.

  --once  an unchanged capture prints a one-line {"unchanged":true,...}
          acknowledgement and exits 3, which is distinct from the error exit; a
          changed capture prints the full snapshot and exits 0.
  --watch the first capture is emitted, and later captures are emitted only when
          the fingerprint differs from the last emitted one. Unchanged polls
          produce no output at all. --if-changed-since seeds the baseline, so a
          resumed watch stays silent through state it has already seen.

Because the fingerprint covers the complete collections, an unchanged capture
carries no unseen event, so the internal cursor advances across it without waking
the reader. Error snapshots are always emitted, never advance the remembered
fingerprint or cursor, and are never masked by the change gate. The cursor is
opaque; pass back the value from the previous snapshot.
EOF
}

OWNER=''; REPO=''; NUMBER=''; USER_LOGIN=''; CURSOR=''; INTERVAL=$MIN_INTERVAL; MODE=''
IF_CHANGED_SINCE=''

# The hexadecimal SHA-256 of stdin, from whichever of the usual three tools exists.
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  else
    openssl dgst -sha256 -r | cut -d' ' -f1
  fi
}

# A one-line acknowledgement that the pull request has not moved: identity, the
# repeated fingerprint, the cursor, and nothing else.
unchanged_line() {
  # unchanged_line SNAPSHOT
  printf '%s' "$1" | jq -c \
    '{schema_version, kind:"unchanged", unchanged:true, captured_at, viewer,
      complete:true, changed:false, fingerprint, cursor,
      pull_request:{repository:.pull_request.repository, number:.pull_request.number,
                    url:.pull_request.url, state:.pull_request.state}}'
}

parse_target() {
  local raw=$1 rest
  case $raw in
    https://github.com/*)
      rest=${raw#https://github.com/}
      rest=${rest%%\?*}; rest=${rest%/}
      OWNER=${rest%%/*}; rest=${rest#*/}
      REPO=${rest%%/*}; rest=${rest#"$REPO"}
      case $rest in
        /pull/*) NUMBER=${rest#/pull/} ;;
        *) die "target must be a pull-request URL: '$raw'" ;;
      esac
      NUMBER=${NUMBER%%/*}
      ;;
    *\#*)
      NUMBER=${raw##*\#}; rest=${raw%%\#*}
      OWNER=${rest%%/*}; REPO=${rest#*/}
      ;;
    *) die "unrecognized target: '$raw'" ;;
  esac
  if ! printf '%s' "$OWNER" | LC_ALL=C grep -qE '^[A-Za-z0-9._-]+$'; then die "invalid owner: '$raw'"; fi
  if ! printf '%s' "$REPO" | LC_ALL=C grep -qE '^[A-Za-z0-9._-]+$'; then die "invalid repository: '$raw'"; fi
  if ! printf '%s' "$NUMBER" | LC_ALL=C grep -qE '^[0-9]+$'; then die "invalid number: '$raw'"; fi
}

gh_call() {
  # gh_call ARGS... — one identity-routed gh invocation.
  local args=("$@")
  if [ -n "$USER_LOGIN" ]; then
    "$identity" exec --user "$USER_LOGIN" --need read "$OWNER/$REPO#$NUMBER" -- gh "${args[@]}"
  else
    "$identity" exec --need read "$OWNER/$REPO#$NUMBER" -- gh "${args[@]}"
  fi
}

CORE_QUERY='query($owner:String!,$name:String!,$number:Int!){
  viewer { login }
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      number title url state isDraft updatedAt
      author { login }
      baseRefName headRefName headRefOid baseRefOid
      mergeable mergeStateStatus reviewDecision
    }
  }
}'

THREAD_QUERY='query($owner:String!,$name:String!,$number:Int!,$after:String){
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      reviewThreads(first:50, after:$after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line
          comments(first:100) {
            pageInfo { hasNextPage }
            nodes { id url createdAt updatedAt lastEditedAt body
                    author { login __typename } }
          }
        }
      }
    }
  }
}'

newer_than_cursor() {
  # Keep events whose newest timestamp is after the cursor. An empty cursor keeps everything.
  local since=''
  case $CURSOR in
    v1:*) since=${CURSOR#v1:} ;;
  esac
  jq -c --arg since "$since" '
    map(select($since == "" or
      ((.edited_at // .updated_at // .created_at // "") > $since)))'
}

capture() {
  local started_epoch started_iso core threads comments reviews checks
  local thread_events='[]' unresolved='[]' after='null' page rc
  started_epoch=$(date +%s)
  started_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  set +e
  core=$(gh_call api graphql -f query="$CORE_QUERY" \
    -F owner="$OWNER" -F name="$REPO" -F number="$NUMBER" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" != 0 ] || [ -z "$core" ]; then
    error_snapshot "$started_iso" "pull-request metadata could not be read"
    return 1
  fi

  # Review threads, fully paginated. A failed page aborts the whole capture.
  while :; do
    set +e
    if [ "$after" = 'null' ]; then
      page=$(gh_call api graphql -f query="$THREAD_QUERY" \
        -F owner="$OWNER" -F name="$REPO" -F number="$NUMBER" 2>/dev/null)
    else
      page=$(gh_call api graphql -f query="$THREAD_QUERY" \
        -F owner="$OWNER" -F name="$REPO" -F number="$NUMBER" -F after="$after" 2>/dev/null)
    fi
    rc=$?
    set -e
    if [ "$rc" != 0 ] || [ -z "$page" ]; then
      error_snapshot "$started_iso" "review-thread pagination failed"
      return 1
    fi
    thread_events=$(jq -nc --slurpfile acc_f <(printf '%s' "$thread_events") \
      --slurpfile page_f <(printf '%s' "$page") '
      ($acc_f[0]) as $acc | ($page_f[0]) as $page |
      $acc + ([$page.data.repository.pullRequest.reviewThreads.nodes[]? |
        . as $t |
        [{id:$t.id, type:"review_thread", thread_id:$t.id,
          path:$t.path, line:$t.line, is_resolved:$t.isResolved, is_outdated:$t.isOutdated,
          author:($t.comments.nodes[0].author.login // null),
          author_is_bot:(($t.comments.nodes[0].author.__typename // "") == "Bot"),
          created_at:($t.comments.nodes[0].createdAt // null),
          updated_at:($t.comments.nodes[0].updatedAt // null),
          edited_at:($t.comments.nodes[0].lastEditedAt // null),
          url:($t.comments.nodes[0].url // null),
          body:($t.comments.nodes[0].body // null)}]
        + [$t.comments.nodes[1:][]? |
           {id:.id, type:"thread_reply", thread_id:$t.id, path:$t.path, line:$t.line,
            author:(.author.login // null),
            author_is_bot:((.author.__typename // "") == "Bot"),
            created_at:.createdAt, updated_at:.updatedAt, edited_at:.lastEditedAt,
            url:.url, body:.body}]
      ] | flatten)')
    unresolved=$(jq -nc --slurpfile acc_f <(printf '%s' "$unresolved") \
      --slurpfile page_f <(printf '%s' "$page") '
      ($acc_f[0]) as $acc | ($page_f[0]) as $page |
      $acc + [$page.data.repository.pullRequest.reviewThreads.nodes[]?
              | select(.isResolved == false) | .id]')
    if [ "$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')" = true ]; then
      after=$(printf '%s' "$page" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
    else
      break
    fi
  done

  set +e
  comments=$(gh_call api --paginate "repos/$OWNER/$REPO/issues/$NUMBER/comments" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" != 0 ] || [ -z "$comments" ]; then
    error_snapshot "$started_iso" "comment pagination failed"
    return 1
  fi

  set +e
  reviews=$(gh_call api --paginate "repos/$OWNER/$REPO/pulls/$NUMBER/reviews" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" != 0 ] || [ -z "$reviews" ]; then
    error_snapshot "$started_iso" "review pagination failed"
    return 1
  fi

  local head_sha
  head_sha=$(printf '%s' "$core" | jq -r '.data.repository.pullRequest.headRefOid // ""')
  set +e
  checks=$(gh_call api --paginate "repos/$OWNER/$REPO/commits/$head_sha/check-runs" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" != 0 ] || [ -z "$checks" ]; then
    checks='{"check_runs":[]}'
  else
    checks=$(printf '%s' "$checks" | jq -sc '{check_runs: (map(.check_runs // []) | add // [])}')
  fi

  local comment_events review_events all_events kept
  comment_events=$(printf '%s' "$comments" | jq -sc 'add // []
    | map(select(type == "object"))
    | map({id:(.id|tostring), type:"comment", thread_id:null,
           author:(.user.login // null),
           author_association:(.author_association // null),
           author_is_bot:((.user.type // "") == "Bot"),
           created_at:.created_at, updated_at:.updated_at,
           edited_at:(if .updated_at != .created_at then .updated_at else null end),
           url:.html_url, body:.body})')
  review_events=$(printf '%s' "$reviews" | jq -sc 'add // []
    | map(select(type == "object"))
    | map(select((.state // "") != "PENDING"))
    | map({id:(.id|tostring), type:"review", thread_id:null,
           author:(.user.login // null),
           author_association:(.author_association // null),
           author_is_bot:((.user.type // "") == "Bot"),
           state:(.state // null),
           created_at:(.submitted_at // null), updated_at:(.submitted_at // null),
           edited_at:null, url:.html_url, body:.body})')

  all_events=$(jq -nc --slurpfile a_f <(printf '%s' "$comment_events") \
    --slurpfile b_f <(printf '%s' "$review_events") \
    --slurpfile c_f <(printf '%s' "$thread_events") '$a_f[0] + $b_f[0] + $c_f[0]')
  kept=$(printf '%s' "$all_events" | newer_than_cursor)

  # The fingerprint covers every change-relevant field and nothing volatile, so two
  # captures that would tell the reader the same thing produce the same fingerprint.
  # The event collections go in COMPLETE, not cursor-filtered: a filtered digest would
  # fall back to its previous value once the events had been delivered and report a
  # phantom second change, and it is the completeness that makes an unchanged capture
  # provably free of unseen events.
  local fingerprint_input fingerprint
  fingerprint_input=$(jq -nc \
    --slurpfile core_f <(printf '%s' "$core") \
    --slurpfile checks_f <(printf '%s' "$checks") \
    --slurpfile events_f <(printf '%s' "$all_events") \
    --slurpfile unresolved_f <(printf '%s' "$unresolved") \
    '($core_f[0].data.repository.pullRequest) as $pr
     | {state:$pr.state, draft:$pr.isDraft, title:$pr.title,
        head:$pr.headRefOid, base:$pr.baseRefOid,
        base_ref:$pr.baseRefName, head_ref:$pr.headRefName,
        author:($pr.author.login // null), updated_at:$pr.updatedAt,
        mergeable:$pr.mergeable, merge_state:$pr.mergeStateStatus,
        review_decision:$pr.reviewDecision,
        checks:([$checks_f[0].check_runs[]? | "\(.id):\(.conclusion // .status)"] | sort),
        events:([$events_f[0][] |
                 "\(.type):\(.id):\(.created_at // ""):\(.updated_at // ""):\(.edited_at // ""):\(.is_resolved // "")"]
                | sort),
        unresolved:($unresolved_f[0] | sort)}')
  fingerprint="sha256:$(printf '%s' "$fingerprint_input" | sha256_hex)"

  local next_cursor duration
  next_cursor="v1:$started_iso"
  duration=$(( $(date +%s) - started_epoch ))

  jq -nc \
    --argjson schema_version "$SCHEMA_VERSION" \
    --arg captured_at "$started_iso" \
    --argjson duration_ms "$(( duration * 1000 ))" \
    --slurpfile core_f <(printf '%s' "$core") \
    --slurpfile checks_f <(printf '%s' "$checks") \
    --slurpfile events_f <(printf '%s' "$kept") \
    --slurpfile unresolved_f <(printf '%s' "$unresolved") \
    --arg repo "$OWNER/$REPO" \
    --arg cursor "$next_cursor" \
    --arg previous "$CURSOR" \
    --arg fingerprint "$fingerprint" \
    --arg since "$IF_CHANGED_SINCE" \
    '($core_f[0]) as $core
     | ($checks_f[0]) as $checks
     | ($events_f[0]) as $events
     | ($unresolved_f[0]) as $unresolved
     | ($core.data.repository.pullRequest) as $pr
     | ($checks.check_runs // []) as $runs
     | {schema_version:$schema_version, kind:"snapshot", captured_at:$captured_at,
        duration_ms:$duration_ms,
        viewer:($core.data.viewer.login // null),
        complete:true,
        fingerprint:$fingerprint,
        changed:($since == "" or $fingerprint != $since),
        previous_cursor:(if $previous=="" then null else $previous end),
        cursor:$cursor,
        pull_request:{
          repository:$repo, number:$pr.number, title:$pr.title, url:$pr.url,
          state:$pr.state, is_draft:$pr.isDraft, author:($pr.author.login // null),
          base_ref:$pr.baseRefName, head_ref:$pr.headRefName,
          head_sha:$pr.headRefOid, base_sha:$pr.baseRefOid, merge_base:null,
          updated_at:$pr.updatedAt, mergeable:$pr.mergeable,
          merge_state_status:$pr.mergeStateStatus, review_decision:$pr.reviewDecision },
        checks:{
          total:($runs|length),
          pending:([$runs[] | select(.status != "completed")]|length),
          failing:([$runs[] | select(((.conclusion // "") | ascii_downcase) as $c
                     | $c == "failure" or $c == "timed_out" or $c == "cancelled"
                       or $c == "action_required")]|length),
          required_known:false,
          items:[$runs[] | {id:(.id|tostring), name:.name, state:(.conclusion // .status),
                            required:null, url:.html_url}] },
        events:$events,
        unresolved_thread_ids:$unresolved}'
}

error_snapshot() {
  local at=$1 reason=$2
  jq -nc --argjson schema_version "$SCHEMA_VERSION" --arg at "$at" --arg reason "$reason" \
    --arg repo "$OWNER/$REPO" --argjson number "$NUMBER" --arg cursor "$CURSOR" \
    '{schema_version:$schema_version, kind:"error", captured_at:$at, viewer:null,
      complete:false, changed:true, error:$reason,
      previous_cursor:(if $cursor=="" then null else $cursor end),
      cursor:(if $cursor=="" then null else $cursor end),
      pull_request:{repository:$repo, number:$number, url:"", state:null}}'
}

main() {
  need jq
  need gh
  [ -x "$identity" ] || die "gh_identity.sh is missing or not executable beside this script"

  local target=''
  while [ $# -gt 0 ]; do
    case $1 in
      --once) MODE=once; shift ;;
      --watch) MODE=watch; shift ;;
      --if-changed-since) IF_CHANGED_SINCE=${2:?--if-changed-since needs a value}; shift 2 ;;
      --user) USER_LOGIN=${2:?--user needs a value}; shift 2 ;;
      --cursor) CURSOR=${2:?--cursor needs a value}; shift 2 ;;
      --interval) INTERVAL=${2:?--interval needs a value}; shift 2 ;;
      -h | --help) usage; return 0 ;;
      --) shift ;;
      -*) die "unexpected option: $1" ;;
      *) target=$1; shift ;;
    esac
  done
  [ -n "$target" ] || { usage >&2; die "a pull-request target is required"; }
  [ -n "$MODE" ] || MODE=once
  whole_number "$INTERVAL" || die "--interval must be a whole number of seconds"
  if [ "$INTERVAL" -lt "$MIN_INTERVAL" ]; then
    die "--interval must be at least $MIN_INTERVAL seconds"
  fi
  # A baseline that no snapshot could have produced is a caller bug, and comparing
  # against it would silently report every capture as changed. Refuse it here, before
  # a single GitHub call has been paid for.
  if [ -n "$IF_CHANGED_SINCE" ] \
     && ! printf '%s' "$IF_CHANGED_SINCE" | LC_ALL=C grep -qE '^sha256:[0-9a-f]{64}$'; then
    die "--if-changed-since must be a fingerprint from a previous snapshot (sha256:<64 hex>)"
  fi
  parse_target "$target"

  local snapshot rc
  if [ "$MODE" = once ]; then
    set +e
    snapshot=$(capture)
    rc=$?
    set -e
    if [ "$rc" = 0 ] && [ -n "$IF_CHANGED_SINCE" ] \
       && [ "$(printf '%s' "$snapshot" | jq -r '.changed')" = false ]; then
      unchanged_line "$snapshot"
      return "$EXIT_UNCHANGED"
    fi
    printf '%s\n' "$snapshot"
    return "$rc"
  fi

  # Watch mode. The last emitted fingerprint is the gate: the first capture of a run
  # without a baseline is always emitted, and after that only movement is. A failed
  # capture is emitted and leaves the gate untouched, so recovery reads as a change.
  local last_emitted=$IF_CHANGED_SINCE start elapsed wait_for
  while :; do
    start=$(date +%s)
    set +e
    snapshot=$(capture)
    rc=$?
    set -e
    if [ "$rc" != 0 ]; then
      printf '%s\n' "$snapshot"
    else
      local fingerprint
      fingerprint=$(printf '%s' "$snapshot" | jq -r '.fingerprint')
      if [ "$fingerprint" != "$last_emitted" ]; then
        printf '%s\n' "$snapshot"
        last_emitted=$fingerprint
      fi
      # A quiet capture carries no unseen event, so the cursor may move on without
      # the reader ever being woken.
      CURSOR=$(printf '%s' "$snapshot" | jq -r '.cursor // ""')
    fi
    elapsed=$(( $(date +%s) - start ))
    wait_for=$(( INTERVAL - elapsed ))
    if [ "$wait_for" -lt 0 ]; then wait_for=0; fi
    sleep "$wait_for"
  done
}

main "$@"
