#!/usr/bin/env bash
# Perform exactly ONE approved removal. Re-checks liveness and safety for that item,
# refuses anything classified protected, refuses a path outside the skills' state
# layout or the named project, and exits non-zero with a reason rather than
# proceeding on doubt.
set -euo pipefail

prog=${0##*/}
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
run_lock="$script_dir/run_lock.sh"
inventory="$script_dir/inventory.sh"

die() { printf '%s: %s\n' "$prog" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

usage() {
  cat <<'EOF'
reclaim.sh --item ID [--project PATH] [--dry-run] [--approve-force]

Removes one item, named by an id taken from the inventory:
  worktree:PATH  tmp:PATH  dependency:PATH  k8s-namespace:NAME  image:ID  process:PID

Liveness and safety are re-verified immediately before the removal, because a run can
start between inventory and approval. Protected items are refused. Process termination
requests graceful termination only; escalation needs --approve-force, which is a new,
item-specific approval and never implied by the first one.
EOF
}

ITEM=''
PROJECT=$PWD
DRY_RUN=false
APPROVE_FORCE=false

fresh_item() {
  # Re-run the read-only inventory and return this item's current record.
  "$inventory" --project "$PROJECT" | jq -c --arg id "$ITEM" \
    '[.groups[].items[] | select(.id == $id)] | first // empty'
}

state_root() {
  "$run_lock" list 2>/dev/null | jq -r '.state_root // empty'
}

assert_within() {
  local path=$1 root
  case $path in
    /*) ;;
    *) die "refusing a relative path: $path" ;;
  esac
  if [ -L "$path" ]; then die "refusing a symlinked path: $path"; fi
  root=$(state_root)
  case $path in
    "$root"/*) return 0 ;;
    "$PROJECT"/*) return 0 ;;
  esac
  die "refusing a path outside the skills' state layout or the named project: $path"
}

remove_worktree() {
  local path=$1 skill key run_id runs
  runs=$("$run_lock" list 2>/dev/null || printf '{"runs":[]}')
  skill=$(printf '%s' "$runs" | jq -r --arg p "$path" '[.runs[]|select(.worktree==$p)|.skill]|first // empty')
  key=$(printf '%s' "$runs" | jq -r --arg p "$path" '[.runs[]|select(.worktree==$p)|.key]|first // empty')
  run_id=$(printf '%s' "$runs" | jq -r --arg p "$path" '[.runs[]|select(.worktree==$p)|.run_id]|first // empty')
  [ -n "$run_id" ] || die "no registry entry owns $path; refusing to remove it"
  if ! "$run_lock" safe "$path" >/dev/null 2>&1; then
    "$run_lock" safe "$path" || true
    die "$path is no longer safe to remove"
  fi
  if [ "$DRY_RUN" = true ]; then
    printf '%s: would run: run_lock.sh remove %s %s --run-id %s\n' "$prog" "$skill" "$key" "$run_id"
    return 0
  fi
  "$run_lock" remove "$skill" "$key" --run-id "$run_id"
}

remove_directory() {
  local safe_path=$1
  assert_within "$safe_path"
  [ -d "$safe_path" ] || die "not a directory: $safe_path"
  if [ "$DRY_RUN" = true ]; then
    printf '%s: would remove directory %s\n' "$prog" "$safe_path"
    return 0
  fi
  rm -rf -- "$safe_path"
  jq -nc --arg p "$safe_path" '{result:"removed", path:$p}'
}

remove_namespace() {
  local ns=$1 endpoint context
  need kubectl
  context=$(kubectl config current-context 2>/dev/null || printf '')
  endpoint=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || printf '')
  case $endpoint in
    https://127.0.0.1:* | https://localhost:* | https://0.0.0.0:* | https://192.168.* | https://10.*) ;;
    *) die "context '$context' at '$endpoint' is not positively local and single-user; failing closed" ;;
  esac
  local skill run_id
  skill=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.team-agent-skill}' 2>/dev/null || printf '')
  run_id=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.team-agent-run}' 2>/dev/null || printf '')
  if [ -z "$skill" ] || [ -z "$run_id" ]; then
    die "namespace $ns does not carry this skill family's ownership labels"
  fi
  if [ "$DRY_RUN" = true ]; then
    printf '%s: would run: kubectl delete namespace %s\n' "$prog" "$ns"
    return 0
  fi
  kubectl delete namespace "$ns"
}

prune_worktree_registrations() {
  need git
  git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "$PROJECT is not a git working tree"
  if [ "$DRY_RUN" = true ]; then
    printf '%s: would run: git -C %s worktree prune\n' "$prog" "$PROJECT"
    return 0
  fi
  git -C "$PROJECT" worktree prune
  jq -nc --arg p "$PROJECT" '{result:"pruned", project:$p}'
}

remove_image() {
  local id=$1 runtime='' label
  if command -v docker >/dev/null 2>&1; then runtime=docker
  elif command -v podman >/dev/null 2>&1; then runtime=podman
  else die "no container runtime found"; fi
  label=$("$runtime" image inspect "$id" --format '{{index .Config.Labels "team-agent-skill"}}' 2>/dev/null || printf '')
  case $label in
    '' | '<no value>') die "image $id does not carry this skill family's ownership labels" ;;
  esac
  if [ "$DRY_RUN" = true ]; then
    printf '%s: would run: %s image rm %s\n' "$prog" "$runtime" "$id"
    return 0
  fi
  "$runtime" image rm "$id"
}

terminate_process() {
  local pid=$1 cwd cmd start_before start_after
  case $pid in
    '' | *[!0-9]*) die "invalid pid: $pid" ;;
  esac
  [ -d "/proc/$pid" ] || die "process $pid is gone"
  cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || printf '')
  case $cwd in
    "$PROJECT" | "$PROJECT"/*) ;;
    *) die "process $pid is not working inside $PROJECT" ;;
  esac
  cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || printf '')
  start_before=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || printf '')
  [ -n "$start_before" ] || die "cannot read the start time of process $pid; refusing on PID-reuse risk"
  if [ "$DRY_RUN" = true ]; then
    printf '%s: would signal TERM to %s (%s)\n' "$prog" "$pid" "$cmd"
    return 0
  fi
  start_after=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || printf '')
  [ "$start_before" = "$start_after" ] || die "process $pid changed identity between checks"
  kill -TERM "$pid"
  sleep 2
  if [ -d "/proc/$pid" ]; then
    if [ "$APPROVE_FORCE" != true ]; then
      die "process $pid did not exit on TERM; escalation needs a new, item-specific --approve-force"
    fi
    kill -KILL "$pid"
  fi
  jq -nc --arg p "$pid" '{result:"terminated", pid:$p}'
}

main() {
  need jq
  [ -x "$run_lock" ] || die "run_lock.sh is missing or not executable beside this script"
  [ -x "$inventory" ] || die "inventory.sh is missing or not executable beside this script"

  while [ $# -gt 0 ]; do
    case $1 in
      --item) ITEM=${2:?--item needs a value}; shift 2 ;;
      --project) PROJECT=${2:?--project needs a value}; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --approve-force) APPROVE_FORCE=true; shift ;;
      -h | --help) usage; return 0 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ -n "$ITEM" ] || { usage >&2; die "--item is required"; }
  [ -d "$PROJECT" ] || die "project path not found: $PROJECT"
  PROJECT=$(cd -- "$PROJECT" && pwd -P)

  local record classification protected
  record=$(fresh_item)
  [ -n "$record" ] || die "item '$ITEM' is not in the current inventory; it may already be gone"
  classification=$(printf '%s' "$record" | jq -r '.classification')
  protected=$(printf '%s' "$record" | jq -r '.protected')
  if [ "$protected" != false ]; then
    die "item '$ITEM' is classified '$classification' and is protected: $(printf '%s' "$record" | jq -r '.reason')"
  fi
  case $classification in
    stale | orphan) ;;
    *) die "item '$ITEM' is classified '$classification'; only stale and orphan items are reclaimable" ;;
  esac

  case $ITEM in
    worktree:*) remove_worktree "${ITEM#worktree:}" ;;
    tmp:*) remove_directory "${ITEM#tmp:}" ;;
    dependency:*) remove_directory "${ITEM#dependency:}" ;;
    git-worktree-registration:*) prune_worktree_registrations ;;
    k8s-namespace:*) remove_namespace "${ITEM#k8s-namespace:}" ;;
    image:*) remove_image "${ITEM#image:}" ;;
    process:*) terminate_process "${ITEM#process:}" ;;
    *) die "unsupported item kind: $ITEM" ;;
  esac
}

main "$@"
