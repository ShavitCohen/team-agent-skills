#!/usr/bin/env bash
# shared-component: run_lock.sh v2 sha256=7abf6b4303ad4b07d1890b45ded2357ae2d1a9f5941319c9a8ee19de621a6d8b
# Run locks, lease liveness, run registry, worktree paths, and safe removal.
# Shared by every skill in this family so that locking, registration, and cleanup
# behave identically and Clean Memory can read the same records.
set -euo pipefail

prog=${0##*/}
SCHEMA_VERSION=1
DEFAULT_TTL=900
MIN_TTL=60

die() { printf '%s: %s\n' "$prog" "$*" >&2; exit 2; }
warn() { printf '%s: %s\n' "$prog" "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

now() { date +%s; }

usage() {
  cat <<'EOF'
run_lock.sh acquire SKILL KEY [--ttl SECONDS] [--pid PID] [--meta JSON]
run_lock.sh resume  SKILL KEY --run-id RUN_ID
run_lock.sh touch   SKILL KEY
run_lock.sh with    SKILL KEY -- COMMAND [ARGS...]
run_lock.sh release SKILL KEY [--state finished|retained]
run_lock.sh status  SKILL KEY
run_lock.sh list    [SKILL]
run_lock.sh path    SKILL OWNER REPO KIND NUMBER
run_lock.sh resource-acquire KIND KEY --run-id RUN_ID
run_lock.sh resource-release KIND KEY --run-id RUN_ID
run_lock.sh sem-acquire KIND KEY --run-id RUN_ID [--capacity N] [--ttl SECONDS] [--wait SECONDS]
run_lock.sh sem-release KIND KEY --run-id RUN_ID
run_lock.sh safe    WORKTREE_PATH
run_lock.sh remove  SKILL KEY --run-id RUN_ID
run_lock.sh reap    [SKILL]

--meta accepts a JSON object and may carry worktree, clone, mode
(editable | disposable-verification), branch, head_sha, target and
artifact_globs. State lives under TEAM_SKILLS_STATE_DIR when set,
otherwise under the user state directory.

sem-acquire is a bounded counting semaphore: up to N holders (default 2)
share KIND/KEY, and further acquirers queue until a slot frees or --wait
seconds (default TEAM_SKILLS_SEM_WAIT or 3600) pass, then exit 3. The
machine-wide heavy-task queue is kind "heavy", key "local", capacity 2.
touch and with refresh held slots; release drops the run's slots.
EOF
}

# ---------------------------------------------------------------- validation

canon() {
  local value=$1 what=$2
  case $value in
    '' | . | ..) die "invalid $what: empty or dot component" ;;
    */* | *\\*) die "invalid $what: path separator in '$value'" ;;
    *..*) die "invalid $what: parent reference in '$value'" ;;
  esac
  if ! printf '%s' "$value" | LC_ALL=C grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    die "invalid $what: '$value' must match [A-Za-z0-9][A-Za-z0-9._-]*"
  fi
  printf '%s' "$value"
}

canon_number() {
  local value=$1
  if ! printf '%s' "$value" | LC_ALL=C grep -qE '^[0-9]+$'; then
    die "invalid number: '$value'"
  fi
  printf '%s' "$value"
}

canon_kind() {
  case $1 in
    issue | pr | repo) printf '%s' "$1" ;;
    *) die "invalid kind: '$1' (expected issue, pr or repo)" ;;
  esac
}

mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || printf '700'
}

assert_private() {
  local path=$1 perm group other
  if [ -L "$path" ]; then die "refusing symlinked state path: $path"; fi
  perm=$(mode_of "$path")
  perm=${perm: -3}
  group=${perm:1:1}
  other=${perm:2:1}
  case $group$other in
    *[2367]*) die "refusing group- or world-writable state path: $path ($perm)" ;;
  esac
}

abspath() {
  local path=$1 dir base
  case $path in
    /*) ;;
    *) path=$PWD/$path ;;
  esac
  dir=$(dirname -- "$path")
  base=$(basename -- "$path")
  if [ -d "$dir" ]; then
    dir=$(cd -- "$dir" && pwd -P)
  fi
  if [ "$base" = "/" ]; then printf '%s' "$dir"; else printf '%s/%s' "${dir%/}" "$base"; fi
}

# ------------------------------------------------------------------- layout

state_root() {
  local root
  if [ -n "${TEAM_SKILLS_STATE_DIR:-}" ]; then
    root=$TEAM_SKILLS_STATE_DIR
  elif [ -n "${XDG_STATE_HOME:-}" ]; then
    root=$XDG_STATE_HOME/team-agent-skills
  else
    root=${HOME:?HOME is not set}/.local/state/team-agent-skills
  fi
  case $root in
    /*) ;;
    *) die "state root must be an absolute path: $root" ;;
  esac
  if [ ! -d "$root" ]; then
    (umask 077 && mkdir -p "$root")
  fi
  assert_private "$root"
  root=$(cd -- "$root" && pwd -P)
  local sub
  for sub in config locks runs clones worktrees tmp; do
    if [ ! -d "$root/$sub" ]; then (umask 077 && mkdir -p "$root/$sub"); fi
  done
  printf '%s' "$root"
}

lock_dir() { printf '%s/locks/%s/%s.lock' "$1" "$2" "$3"; }
run_file() { printf '%s/runs/%s/%s.json' "$1" "$2" "$3"; }

worktree_root_for() { printf '%s/worktrees/%s' "$1" "$2"; }

new_run_id() {
  printf '%s-%s-%s' "$(now)" "$$" "${RANDOM}${RANDOM}"
}

# --------------------------------------------------------------------- json

json_write() {
  # json_write PATH JSON — atomic, private, never half-read by a concurrent reader.
  local target=$1 body=$2 tmp
  tmp=$target.tmp.$$
  if [ ! -d "$(dirname -- "$target")" ]; then (umask 077 && mkdir -p "$(dirname -- "$target")"); fi
  (umask 077 && printf '%s\n' "$body" > "$tmp")
  mv -f "$tmp" "$target"
}

json_read() {
  # json_read PATH — validates schema_version and refuses an unknown newer document.
  local path=$1 version
  if [ ! -f "$path" ]; then return 1; fi
  if ! jq -e . "$path" >/dev/null 2>&1; then die "corrupt JSON document: $path"; fi
  version=$(jq -r '.schema_version // 0' "$path")
  if [ "$version" -gt "$SCHEMA_VERSION" ] 2>/dev/null; then
    die "document $path declares schema_version $version, newer than $SCHEMA_VERSION; refusing to interpret it"
  fi
  cat "$path"
}

# ---------------------------------------------------------------- liveness

classify_lock() {
  # classify_lock LOCKDIR -> free | live | stale
  local dir=$1 lease heartbeat ttl age
  if [ ! -d "$dir" ]; then printf 'free'; return 0; fi
  if [ ! -f "$dir/lease.json" ]; then printf 'stale'; return 0; fi
  lease=$(json_read "$dir/lease.json") || { printf 'stale'; return 0; }
  heartbeat=$(printf '%s' "$lease" | jq -r '.heartbeat // 0')
  ttl=$(printf '%s' "$lease" | jq -r '.ttl // 0')
  age=$(( $(now) - heartbeat ))
  if [ "$age" -le "$ttl" ]; then printf 'live'; else printf 'stale'; fi
}

write_lease() {
  local dir=$1 skill=$2 key=$3 run_id=$4 ttl=$5 pid=$6 acquired=$7
  json_write "$dir/lease.json" "$(jq -nc \
    --argjson schema_version "$SCHEMA_VERSION" \
    --arg skill "$skill" --arg key "$key" --arg run_id "$run_id" \
    --argjson ttl "$ttl" --argjson heartbeat "$(now)" --argjson acquired_at "$acquired" \
    --arg pid "$pid" \
    '{schema_version:$schema_version, kind:"lease", skill:$skill, key:$key,
      run_id:$run_id, pid:(if $pid=="" then null else ($pid|tonumber) end),
      acquired_at:$acquired_at, heartbeat:$heartbeat, ttl:$ttl}')"
}

write_run() {
  local file=$1 skill=$2 key=$3 run_id=$4 ttl=$5 pid=$6 meta=$7 started=$8 state=$9
  json_write "$file" "$(jq -nc \
    --argjson schema_version "$SCHEMA_VERSION" \
    --arg skill "$skill" --arg key "$key" --arg run_id "$run_id" \
    --argjson ttl "$ttl" --argjson heartbeat "$(now)" --argjson started_at "$started" \
    --arg pid "$pid" --arg state "$state" --argjson meta "$meta" \
    '{schema_version:$schema_version, kind:"run", skill:$skill, key:$key, run_id:$run_id,
      target:($meta.target // {owner:"unknown", repository:"unknown", kind:"repo", number:null}),
      worktree:($meta.worktree // null), clone:($meta.clone // null),
      mode:($meta.mode // "editable"), branch:($meta.branch // null),
      head_sha:($meta.head_sha // null), base_sha:($meta.base_sha // null),
      started_at:$started_at, heartbeat:$heartbeat, ttl:$ttl,
      pid:(if $pid=="" then null else ($pid|tonumber) end),
      state:$state, artifact_globs:($meta.artifact_globs // []),
      meta:($meta | del(.target,.worktree,.clone,.mode,.branch,.head_sha,.base_sha,.artifact_globs))}')"
}

bump_heartbeat() {
  local file=$1 body
  if [ ! -f "$file" ]; then return 0; fi
  body=$(json_read "$file") || return 0
  json_write "$file" "$(printf '%s' "$body" | jq -c --argjson t "$(now)" '.heartbeat = $t')"
}

# ------------------------------------------------------------------ commands

cmd_acquire() {
  local skill key ttl=$DEFAULT_TTL pid='' meta='{}'
  skill=$(canon "${1:-}" skill); key=$(canon "${2:-}" key); shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --ttl) ttl=${2:?--ttl needs a value}; shift 2 ;;
      --pid) pid=${2:?--pid needs a value}; shift 2 ;;
      --meta) meta=${2:?--meta needs a value}; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  ttl=$(canon_number "$ttl")
  if [ "$ttl" -lt "$MIN_TTL" ]; then die "ttl must be at least $MIN_TTL seconds"; fi
  if [ -n "$pid" ]; then pid=$(canon_number "$pid"); fi
  if ! printf '%s' "$meta" | jq -e 'type == "object"' >/dev/null 2>&1; then
    die "--meta must be a JSON object"
  fi

  local root dir file run_id state
  root=$(state_root)
  dir=$(lock_dir "$root" "$skill" "$key")
  file=$(run_file "$root" "$skill" "$key")
  if [ ! -d "$(dirname -- "$dir")" ]; then (umask 077 && mkdir -p "$(dirname -- "$dir")"); fi

  if (umask 077 && mkdir "$dir" 2>/dev/null); then
    state=acquired
  else
    case $(classify_lock "$dir") in
      live)
        jq -nc --arg skill "$skill" --arg key "$key" \
          --argjson lease "$(cat "$dir/lease.json" 2>/dev/null || printf 'null')" \
          --argjson run "$(cat "$file" 2>/dev/null || printf 'null')" \
          '{result:"held", skill:$skill, key:$key, lease:$lease, run:$run}'
        exit 3
        ;;
      *) state=takeover ;;
    esac
  fi

  run_id=$(new_run_id)
  write_lease "$dir" "$skill" "$key" "$run_id" "$ttl" "$pid" "$(now)"
  local started
  started=$(now)
  if [ -f "$file" ] && [ "$state" = takeover ]; then
    started=$(jq -r '.started_at // empty' "$file" 2>/dev/null || printf '')
    if [ -z "$started" ]; then started=$(now); fi
    meta=$(jq -nc --argjson old "$(cat "$file")" --argjson new "$meta" \
      '{worktree:$old.worktree, clone:$old.clone, mode:$old.mode, branch:$old.branch,
        head_sha:$old.head_sha, base_sha:$old.base_sha, target:$old.target,
        artifact_globs:$old.artifact_globs} * ($old.meta // {}) * $new
       | with_entries(select(.value != null))')
  fi
  write_run "$file" "$skill" "$key" "$run_id" "$ttl" "$pid" "$meta" "$started" active

  jq -nc --arg result "$state" --arg run_id "$run_id" --arg root "$root" \
    --arg lock "$dir" --arg registry "$file" \
    --arg worktree_root "$(worktree_root_for "$root" "$skill")" \
    --arg tmp "$root/tmp/$run_id" --argjson ttl "$ttl" \
    '{result:$result, run_id:$run_id, state_root:$root, lock:$lock, registry:$registry,
      worktree_root:$worktree_root, tmp:$tmp, ttl:$ttl}'
}

cmd_resume() {
  local skill key run_id=''
  skill=$(canon "${1:-}" skill); key=$(canon "${2:-}" key); shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --run-id) run_id=${2:?--run-id needs a value}; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$run_id" ] || die "resume requires --run-id"
  run_id=$(canon "$run_id" run-id)

  local root dir file existing
  root=$(state_root)
  dir=$(lock_dir "$root" "$skill" "$key")
  file=$(run_file "$root" "$skill" "$key")
  [ -f "$file" ] || die "no registry entry for $skill/$key"
  existing=$(jq -r '.run_id' "$file")
  [ "$existing" = "$run_id" ] || die "registry entry for $skill/$key belongs to run $existing"

  if [ -d "$dir" ] && [ -f "$dir/lease.json" ]; then
    local holder
    holder=$(jq -r '.run_id // ""' "$dir/lease.json")
    if [ "$holder" != "$run_id" ] && [ "$(classify_lock "$dir")" = live ]; then
      die "lock for $skill/$key is held by a live run: $holder"
    fi
  else
    (umask 077 && mkdir -p "$dir")
  fi
  local ttl pid started
  ttl=$(jq -r '.ttl' "$file"); pid=$(jq -r '.pid // "" | tostring' "$file")
  if [ "$pid" = "null" ]; then pid=''; fi
  started=$(jq -r '.started_at' "$file")
  write_lease "$dir" "$skill" "$key" "$run_id" "$ttl" "$pid" "$started"
  bump_heartbeat "$file"
  jq -nc --arg run_id "$run_id" --arg registry "$file" \
    --argjson run "$(cat "$file")" '{result:"resumed", run_id:$run_id, registry:$registry, run:$run}'
}

cmd_touch() {
  local skill key root dir file
  skill=$(canon "${1:-}" skill); key=$(canon "${2:-}" key)
  root=$(state_root)
  dir=$(lock_dir "$root" "$skill" "$key")
  file=$(run_file "$root" "$skill" "$key")
  [ -d "$dir" ] || die "no lock held for $skill/$key"
  local lease
  lease=$(json_read "$dir/lease.json") || die "lock for $skill/$key has no lease"
  json_write "$dir/lease.json" "$(printf '%s' "$lease" | jq -c --argjson t "$(now)" '.heartbeat = $t')"
  bump_heartbeat "$file"
  local held_run sem_lease
  held_run=$(printf '%s' "$lease" | jq -r '.run_id // ""')
  if [ -n "$held_run" ]; then
    for sem_lease in "$root"/locks/sem-*/*/slot-*.lock/lease.json; do
      [ -f "$sem_lease" ] || continue
      if [ "$(jq -r '.run_id // ""' "$sem_lease" 2>/dev/null)" = "$held_run" ]; then
        bump_heartbeat "$sem_lease"
      fi
    done
  fi
  printf '%s\n' "$(now)"
}

cmd_with() {
  local skill key interval ttl rc=0 refresher=''
  skill=$(canon "${1:-}" skill); key=$(canon "${2:-}" key); shift 2
  if [ "${1:-}" = "--" ]; then shift; fi
  [ $# -gt 0 ] || die "with requires a command after --"

  local root dir
  root=$(state_root)
  dir=$(lock_dir "$root" "$skill" "$key")
  [ -d "$dir" ] || die "no lock held for $skill/$key"
  ttl=$(jq -r '.ttl // 900' "$dir/lease.json")
  interval=${TEAM_SKILLS_HEARTBEAT_INTERVAL:-$(( ttl / 3 ))}
  if [ "$interval" -lt 5 ]; then interval=5; fi

  (
    while sleep "$interval"; do
      "$0" touch "$skill" "$key" >/dev/null 2>&1 || exit 0
    done
  ) &
  refresher=$!

  set +e
  "$@"
  rc=$?
  set -e

  if [ -n "$refresher" ]; then
    kill "$refresher" 2>/dev/null || true
    wait "$refresher" 2>/dev/null || true
  fi
  "$0" touch "$skill" "$key" >/dev/null 2>&1 || true
  return "$rc"
}

cmd_release() {
  local skill key state=finished
  skill=$(canon "${1:-}" skill); key=$(canon "${2:-}" key); shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --state) state=${2:?--state needs a value}; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  case $state in finished | retained) ;; *) die "--state must be finished or retained" ;; esac

  local root dir file safe_lock
  root=$(state_root)
  dir=$(lock_dir "$root" "$skill" "$key")
  file=$(run_file "$root" "$skill" "$key")
  if [ -f "$file" ]; then
    json_write "$file" "$(json_read "$file" | jq -c --arg s "$state" --argjson t "$(now)" \
      '.state = $s | .heartbeat = $t')"
  fi
  if [ -d "$dir" ]; then
    local held_run sem_dir
    held_run=$(jq -r '.run_id // ""' "$dir/lease.json" 2>/dev/null || printf '')
    if [ -n "$held_run" ]; then
      for sem_dir in "$root"/locks/sem-*/*/slot-*.lock; do
        [ -d "$sem_dir" ] || continue
        if [ "$(jq -r '.run_id // ""' "$sem_dir/lease.json" 2>/dev/null || printf '')" = "$held_run" ]; then
          case $sem_dir in
            "$root"/locks/*) rm -rf -- "$sem_dir" ;;
          esac
        fi
      done
    fi
    safe_lock=$dir
    case $safe_lock in
      "$root"/locks/*) rm -rf -- "$safe_lock" ;;
      *) die "refusing to remove a lock outside the state layout: $safe_lock" ;;
    esac
  fi
  jq -nc --arg skill "$skill" --arg key "$key" --arg state "$state" \
    '{result:"released", skill:$skill, key:$key, state:$state}'
}

cmd_status() {
  local skill key root dir file
  skill=$(canon "${1:-}" skill); key=$(canon "${2:-}" key)
  root=$(state_root)
  dir=$(lock_dir "$root" "$skill" "$key")
  file=$(run_file "$root" "$skill" "$key")
  jq -nc --arg skill "$skill" --arg key "$key" --arg lock "$(classify_lock "$dir")" \
    --argjson lease "$(cat "$dir/lease.json" 2>/dev/null || printf 'null')" \
    --argjson run "$(cat "$file" 2>/dev/null || printf 'null')" \
    --argjson at "$(now)" \
    '{skill:$skill, key:$key, lock:$lock, at:$at, lease:$lease, run:$run}'
}

cmd_list() {
  local root skill='' dir entry key lock out
  root=$(state_root)
  if [ $# -gt 0 ]; then skill=$(canon "$1" skill); fi
  out='[]'
  for dir in "$root"/runs/*; do
    [ -d "$dir" ] || continue
    local s
    s=$(basename -- "$dir")
    if [ -n "$skill" ] && [ "$s" != "$skill" ]; then continue; fi
    for entry in "$dir"/*.json; do
      [ -f "$entry" ] || continue
      key=$(basename -- "$entry" .json)
      lock=$(classify_lock "$(lock_dir "$root" "$s" "$key")")
      out=$(jq -nc --argjson acc "$out" --argjson run "$(cat "$entry")" --arg lock "$lock" \
        '$acc + [$run + {lock:$lock}]')
    done
  done
  jq -nc --argjson runs "$out" --arg state_root "$root" --argjson at "$(now)" \
    '{state_root:$state_root, at:$at, runs:$runs}'
}

cmd_path() {
  local skill owner repo kind number root
  skill=$(canon "${1:-}" skill)
  owner=$(canon "${2:-}" owner)
  repo=$(canon "${3:-}" repository)
  kind=$(canon_kind "${4:-}")
  number=$(canon_number "${5:-}")
  root=$(state_root)
  printf '%s/%s-%s-%s%s\n' "$(worktree_root_for "$root" "$skill")" "$owner" "$repo" "$kind" "$number"
}

cmd_resource_acquire() {
  local kind key run_id=''
  kind=$(canon "${1:-}" resource-kind); key=$(canon "${2:-}" resource-key); shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --run-id) run_id=${2:?--run-id needs a value}; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$run_id" ] || die "resource-acquire requires --run-id"
  run_id=$(canon "$run_id" run-id)

  local root dir waited=0
  root=$(state_root)
  dir="$root/locks/resource-$kind/$key.lock"
  if [ ! -d "$(dirname -- "$dir")" ]; then (umask 077 && mkdir -p "$(dirname -- "$dir")"); fi
  while ! (umask 077 && mkdir "$dir" 2>/dev/null); do
    if [ "$(classify_lock "$dir")" != live ]; then
      case $dir in
        "$root"/locks/*) rm -rf -- "$dir" ;;
        *) die "refusing to remove a lock outside the state layout: $dir" ;;
      esac
      continue
    fi
    waited=$(( waited + 1 ))
    if [ "$waited" -gt "${TEAM_SKILLS_RESOURCE_WAIT:-60}" ]; then
      die "resource lock $kind/$key is held by a live run"
    fi
    sleep 1
  done
  write_lease "$dir" "resource-$kind" "$key" "$run_id" 300 '' "$(now)"
  jq -nc --arg kind "$kind" --arg key "$key" --arg run_id "$run_id" --arg lock "$dir" \
    '{result:"acquired", resource:$kind, key:$key, run_id:$run_id, lock:$lock}'
}

cmd_resource_release() {
  local kind key run_id='' root dir holder safe_lock
  kind=$(canon "${1:-}" resource-kind); key=$(canon "${2:-}" resource-key); shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --run-id) run_id=${2:?--run-id needs a value}; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$run_id" ] || die "resource-release requires --run-id"
  root=$(state_root)
  dir="$root/locks/resource-$kind/$key.lock"
  if [ -d "$dir" ]; then
    holder=$(jq -r '.run_id // ""' "$dir/lease.json" 2>/dev/null || printf '')
    if [ -n "$holder" ] && [ "$holder" != "$run_id" ]; then
      die "resource lock $kind/$key is held by run $holder, not $run_id"
    fi
    safe_lock=$dir
    case $safe_lock in
      "$root"/locks/*) rm -rf -- "$safe_lock" ;;
      *) die "refusing to remove a lock outside the state layout: $safe_lock" ;;
    esac
  fi
  jq -nc --arg kind "$kind" --arg key "$key" '{result:"released", resource:$kind, key:$key}'
}

cmd_sem_acquire() {
  # A bounded counting semaphore: capacity N holders share KIND/KEY, each on its
  # own slot lease. Further acquirers queue until a slot frees or the wait limit
  # passes. The machine-wide heavy-task queue is kind "heavy", key "local",
  # capacity 2 — the queue that keeps parallel test suites, builds, and QA
  # environments from saturating the machine.
  local kind key run_id='' capacity=2 ttl=$DEFAULT_TTL wait_limit=${TEAM_SKILLS_SEM_WAIT:-3600}
  kind=$(canon "${1:-}" semaphore-kind); key=$(canon "${2:-}" semaphore-key); shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --run-id) run_id=${2:?--run-id needs a value}; shift 2 ;;
      --capacity) capacity=${2:?--capacity needs a value}; shift 2 ;;
      --ttl) ttl=${2:?--ttl needs a value}; shift 2 ;;
      --wait) wait_limit=${2:?--wait needs a value}; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$run_id" ] || die "sem-acquire requires --run-id"
  run_id=$(canon "$run_id" run-id)
  capacity=$(canon_number "$capacity")
  [ "$capacity" -ge 1 ] || die "capacity must be at least 1"
  ttl=$(canon_number "$ttl")
  if [ "$ttl" -lt "$MIN_TTL" ]; then die "ttl must be at least $MIN_TTL seconds"; fi
  wait_limit=$(canon_number "$wait_limit")

  local root base dir slot waited=0
  root=$(state_root)
  base="$root/locks/sem-$kind/$key"
  if [ ! -d "$base" ]; then (umask 077 && mkdir -p "$base"); fi

  while :; do
    slot=1
    while [ "$slot" -le "$capacity" ]; do
      dir="$base/slot-$slot.lock"
      if [ -f "$dir/lease.json" ] \
        && [ "$(jq -r '.run_id // ""' "$dir/lease.json" 2>/dev/null)" = "$run_id" ]; then
        write_lease "$dir" "sem-$kind" "$key" "$run_id" "$ttl" '' "$(now)"
        jq -nc --arg kind "$kind" --arg key "$key" --arg run_id "$run_id" \
          --argjson slot "$slot" --argjson capacity "$capacity" --arg lock "$dir" \
          '{result:"acquired", semaphore:$kind, key:$key, slot:$slot, capacity:$capacity,
            run_id:$run_id, lock:$lock}'
        return 0
      fi
      if (umask 077 && mkdir "$dir" 2>/dev/null); then
        write_lease "$dir" "sem-$kind" "$key" "$run_id" "$ttl" '' "$(now)"
        jq -nc --arg kind "$kind" --arg key "$key" --arg run_id "$run_id" \
          --argjson slot "$slot" --argjson capacity "$capacity" --arg lock "$dir" \
          '{result:"acquired", semaphore:$kind, key:$key, slot:$slot, capacity:$capacity,
            run_id:$run_id, lock:$lock}'
        return 0
      fi
      if [ -d "$dir" ] && [ "$(classify_lock "$dir")" != live ]; then
        case $dir in
          "$root"/locks/*) rm -rf -- "$dir" ;;
          *) die "refusing to remove a lock outside the state layout: $dir" ;;
        esac
        continue
      fi
      slot=$(( slot + 1 ))
    done
    if [ "$waited" -ge "$wait_limit" ]; then
      jq -nc --arg kind "$kind" --arg key "$key" --arg run_id "$run_id" \
        --argjson capacity "$capacity" --argjson waited "$waited" \
        '{result:"exhausted", semaphore:$kind, key:$key, run_id:$run_id,
          capacity:$capacity, waited:$waited}'
      exit 3
    fi
    sleep 5
    waited=$(( waited + 5 ))
  done
}

cmd_sem_release() {
  local kind key run_id='' root base dir holder released=0
  kind=$(canon "${1:-}" semaphore-kind); key=$(canon "${2:-}" semaphore-key); shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --run-id) run_id=${2:?--run-id needs a value}; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$run_id" ] || die "sem-release requires --run-id"
  run_id=$(canon "$run_id" run-id)
  root=$(state_root)
  base="$root/locks/sem-$kind/$key"
  for dir in "$base"/slot-*.lock; do
    [ -d "$dir" ] || continue
    holder=$(jq -r '.run_id // ""' "$dir/lease.json" 2>/dev/null || printf '')
    [ "$holder" = "$run_id" ] || continue
    case $dir in
      "$root"/locks/*) rm -rf -- "$dir"; released=$(( released + 1 )) ;;
      *) die "refusing to remove a lock outside the state layout: $dir" ;;
    esac
  done
  jq -nc --arg kind "$kind" --arg key "$key" --arg run_id "$run_id" --argjson released "$released" \
    '{result:"released", semaphore:$kind, key:$key, run_id:$run_id, slots_released:$released}'
}

find_run_for_worktree() {
  local root=$1 target=$2
  local dir entry
  for dir in "$root"/runs/*; do
    [ -d "$dir" ] || continue
    for entry in "$dir"/*.json; do
      [ -f "$entry" ] || continue
      if [ "$(jq -r '.worktree // ""' "$entry")" = "$target" ]; then
        cat "$entry"
        return 0
      fi
    done
  done
  return 1
}

cmd_safe() {
  local path root abs run mode reasons='[]' safe=true globs='[]'
  path=${1:?safe requires a worktree path}
  root=$(state_root)
  abs=$(abspath "$path")
  if [ -L "$abs" ]; then
    jq -nc --arg p "$abs" '{path:$p, safe:false, reasons:["path is a symlink"]}'
    return 1
  fi
  if [ ! -d "$abs" ]; then
    jq -nc --arg p "$abs" '{path:$p, safe:false, reasons:["path does not exist"]}'
    return 1
  fi
  abs=$(cd -- "$abs" && pwd -P)
  mode=editable
  if run=$(find_run_for_worktree "$root" "$abs"); then
    mode=$(printf '%s' "$run" | jq -r '.mode // "editable"')
    globs=$(printf '%s' "$run" | jq -c '.artifact_globs // []')
  fi

  add_reason() { reasons=$(jq -nc --argjson a "$reasons" --arg r "$1" '$a + [$r]'); safe=false; }

  if ! git -C "$abs" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    add_reason "not a git working tree"
    jq -nc --arg p "$abs" --arg m "$mode" --argjson r "$reasons" \
      '{path:$p, mode:$m, safe:false, reasons:$r}'
    return 1
  fi

  local gitdir
  gitdir=$(git -C "$abs" rev-parse --git-dir 2>/dev/null || printf '')
  case $gitdir in
    /*) ;;
    *) gitdir=$abs/$gitdir ;;
  esac
  local marker
  for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    if [ -e "$gitdir/$marker" ]; then add_reason "git operation in progress: $marker"; fi
  done

  local tracked untracked
  tracked=$(git -C "$abs" status --porcelain --untracked-files=no 2>/dev/null || printf '')
  untracked=$(git -C "$abs" ls-files --others --exclude-standard 2>/dev/null || printf '')
  if [ -n "$tracked" ]; then add_reason "uncommitted changes to tracked files"; fi

  if [ -n "$untracked" ]; then
    if [ "$mode" = editable ]; then
      add_reason "untracked files present"
    else
      local f matched
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        matched=$(jq -nc --argjson g "$globs" --arg f "$f" \
          '[$g[] | select($f | test(.))] | length')
        if [ "$matched" = "0" ]; then
          add_reason "unexplained path in a disposable checkout: $f"
        fi
      done <<EOF
$untracked
EOF
    fi
  fi

  local upstream ahead
  upstream=$(git -C "$abs" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || printf '')
  if [ -n "$upstream" ]; then
    ahead=$(git -C "$abs" rev-list --count "$upstream"..HEAD 2>/dev/null || printf '0')
    if [ "$ahead" != "0" ]; then add_reason "$ahead commit(s) not present on $upstream"; fi
  else
    if [ "$mode" = editable ]; then
      local head_branch
      head_branch=$(git -C "$abs" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '')
      if [ -n "$head_branch" ]; then add_reason "branch $head_branch has no upstream to compare against"; fi
    fi
  fi

  if [ "$mode" = disposable-verification ]; then
    local commits
    commits=$(git -C "$abs" rev-list --count HEAD --not --remotes 2>/dev/null || printf '0')
    if [ "$commits" != "0" ]; then add_reason "$commits commit(s) created in a disposable checkout"; fi
  fi

  jq -nc --arg p "$abs" --arg m "$mode" --argjson r "$reasons" --argjson s "$safe" \
    '{path:$p, mode:$m, safe:$s, reasons:$r}'
  if [ "$safe" = true ]; then return 0; fi
  return 1
}

cmd_remove() {
  local skill key run_id=''
  skill=$(canon "${1:-}" skill); key=$(canon "${2:-}" key); shift 2
  while [ $# -gt 0 ]; do
    case $1 in
      --run-id) run_id=${2:?--run-id needs a value}; shift 2 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$run_id" ] || die "remove requires --run-id"

  local root file entry worktree clone owner_run wt_root safe_path
  root=$(state_root)
  file=$(run_file "$root" "$skill" "$key")
  [ -f "$file" ] || die "no registry entry for $skill/$key"
  entry=$(json_read "$file")
  owner_run=$(printf '%s' "$entry" | jq -r '.run_id')
  [ "$owner_run" = "$run_id" ] || die "registry entry for $skill/$key belongs to run $owner_run"
  worktree=$(printf '%s' "$entry" | jq -r '.worktree // ""')
  clone=$(printf '%s' "$entry" | jq -r '.clone // ""')
  [ -n "$worktree" ] || die "run $run_id has no registered worktree"

  wt_root=$(worktree_root_for "$root" "$skill")
  case $worktree in
    "$wt_root"/*) ;;
    *) die "refusing to remove a path outside this skill's worktree root: $worktree" ;;
  esac
  if [ -L "$worktree" ]; then die "refusing to remove a symlinked worktree: $worktree"; fi

  if ! cmd_safe "$worktree" >/dev/null 2>&1; then
    json_write "$file" "$(printf '%s' "$entry" | jq -c '.state = "retained"')"
    cmd_safe "$worktree" || true
    printf '%s: retained %s — unsafe to remove\n' "$prog" "$worktree" >&2
    exit 4
  fi

  local locked=0
  if [ -n "$clone" ]; then
    cmd_resource_acquire clone "$(printf '%s' "$clone" | tr '/' '-' | tr -c 'A-Za-z0-9._-' '-')" --run-id "$run_id" >/dev/null
    locked=1
  fi
  local removed=git-worktree
  if [ -n "$clone" ] && git -C "$clone" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $worktree"; then
    git -C "$clone" worktree remove "$worktree"
    git -C "$clone" worktree prune
  else
    safe_path=$worktree
    rm -rf -- "$safe_path"
    removed=directory
  fi
  if [ "$locked" = 1 ]; then
    cmd_resource_release clone "$(printf '%s' "$clone" | tr '/' '-' | tr -c 'A-Za-z0-9._-' '-')" --run-id "$run_id" >/dev/null
  fi

  safe_path="$root/tmp/$run_id"
  if [ -d "$safe_path" ]; then rm -rf -- "$safe_path"; fi

  json_write "$file" "$(printf '%s' "$entry" | jq -c '.state = "finished" | .worktree = null')"
  jq -nc --arg wt "$worktree" --arg how "$removed" \
    '{result:"removed", worktree:$wt, method:$how, branch_kept:true, clone_kept:true}'
}

cmd_reap() {
  local root skill='' out='[]' dir entry key lock
  root=$(state_root)
  if [ $# -gt 0 ]; then skill=$(canon "$1" skill); fi
  for dir in "$root"/runs/*; do
    [ -d "$dir" ] || continue
    local s
    s=$(basename -- "$dir")
    if [ -n "$skill" ] && [ "$s" != "$skill" ]; then continue; fi
    for entry in "$dir"/*.json; do
      [ -f "$entry" ] || continue
      key=$(basename -- "$entry" .json)
      lock=$(classify_lock "$(lock_dir "$root" "$s" "$key")")
      if [ "$lock" = live ]; then continue; fi
      local wt safe_json
      wt=$(jq -r '.worktree // ""' "$entry")
      safe_json='null'
      if [ -n "$wt" ] && [ -d "$wt" ]; then
        safe_json=$(cmd_safe "$wt" 2>/dev/null || true)
        if [ -z "$safe_json" ]; then safe_json='null'; fi
      fi
      out=$(jq -nc --argjson acc "$out" --argjson run "$(cat "$entry")" \
        --arg lock "$lock" --argjson safe "$safe_json" \
        '$acc + [{skill:$run.skill, key:$run.key, run_id:$run.run_id, state:$run.state,
                  worktree:$run.worktree, lock:$lock, removable:$safe}]')
    done
  done
  jq -nc --argjson candidates "$out" \
    '{result:"reap", note:"reporting only; nothing was removed", candidates:$candidates}'
}

# ---------------------------------------------------------------------- main

main() {
  need jq
  need git
  local sub=${1:-}
  if [ $# -gt 0 ]; then shift; fi
  case $sub in
    acquire) cmd_acquire "$@" ;;
    resume) cmd_resume "$@" ;;
    touch) cmd_touch "$@" ;;
    with) cmd_with "$@" ;;
    release) cmd_release "$@" ;;
    status) cmd_status "$@" ;;
    list) cmd_list "$@" ;;
    path) cmd_path "$@" ;;
    resource-acquire) cmd_resource_acquire "$@" ;;
    resource-release) cmd_resource_release "$@" ;;
    sem-acquire) cmd_sem_acquire "$@" ;;
    sem-release) cmd_sem_release "$@" ;;
    safe) cmd_safe "$@" ;;
    remove) cmd_remove "$@" ;;
    reap) cmd_reap "$@" ;;
    -h | --help | help | '') usage ;;
    *) usage >&2; die "unknown subcommand: $sub" ;;
  esac
}

main "$@"
