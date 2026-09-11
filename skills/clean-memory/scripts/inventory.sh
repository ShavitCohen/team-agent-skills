#!/usr/bin/env bash
# Read-only inventory of what this project and its agent skills cost the machine.
# It never deletes, kills, or mutates anything, so it is safe to run while other
# agents are working. Every item defaults to protected.
set -euo pipefail

prog=${0##*/}
SCHEMA_VERSION=1

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
run_lock="$script_dir/run_lock.sh"

die() { printf '%s: %s\n' "$prog" "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
inventory.sh [--project PATH] [--format json]

Emits the classified inventory as JSON (schemas/inventory-v1.json). Read-only:
it performs no deletion, no process signal, and no cluster or container mutation.
Classification is in use | holds work | stale | orphan | unknown; only stale and
orphan are ever offered as candidates, and only with full evidence.
EOF
}

PROJECT=$PWD
FORMAT=json

size_bytes() {
  local path=$1 kb
  if [ ! -e "$path" ]; then printf ''; return 0; fi
  kb=$(du -sk -- "$path" 2>/dev/null | awk 'NR==1{print $1}')
  if [ -z "$kb" ]; then printf ''; return 0; fi
  printf '%s' "$(( kb * 1024 ))"
}

# Whether this machine offers any way to prove that no process holds a path.
# Without it, an expired lease can only ever be classified unknown, never stale.
DETECTION_AVAILABLE=false
if [ -d /proc ] || command -v lsof >/dev/null 2>&1; then DETECTION_AVAILABLE=true; fi

holders_of() {
  # Print PIDs holding PATH open or using it as a working directory.
  local path=$1 pid link
  if [ -d /proc ]; then
    for link in /proc/[0-9]*; do
      pid=${link#/proc/}
      local cwd
      cwd=$(readlink -f "$link/cwd" 2>/dev/null || printf '')
      case $cwd in
        "$path" | "$path"/*) printf '%s\n' "$pid" ;;
      esac
    done
  fi
  if have lsof; then
    lsof -t -- "$path" 2>/dev/null || true
  fi
}

item() {
  # item ID PATH SIZE CLASSIFICATION PROTECTED REASON [OWNER_SKILL] [OWNER_RUN] [TARGET] [HOLDS] [HANDOFF] [COMMAND]
  jq -nc --arg id "$1" --arg path "$2" --arg size "$3" --arg cls "$4" \
    --argjson protected "$5" --arg reason "$6" \
    --arg skill "${7:-}" --arg run "${8:-}" --arg target "${9:-}" \
    --arg holds "${10:-}" --arg handoff "${11:-}" --arg command "${12:-}" \
    '{id:$id,
      path:(if $path=="" then null else $path end),
      size_bytes:(if $size=="" then null else ($size|tonumber) end),
      size_measured:($size != ""),
      owner_skill:(if $skill=="" then null else $skill end),
      owner_run_id:(if $run=="" then null else $run end),
      owner_target:(if $target=="" then null else $target end),
      classification:$cls, protected:$protected, reason:$reason,
      holds:(if $holds=="" then null else $holds end),
      handoff_skill:(if $handoff=="" then null else $handoff end),
      command:(if $command=="" then null else $command end)}'
}

group() {
  jq -nc --arg id "$1" --arg title "$2" --arg status "$3" --arg skipped "$4" \
    --argjson items "$5" \
    '{id:$id, title:$title, status:$status,
      skipped_reason:(if $skipped=="" then null else $skipped end),
      items:$items,
      reclaimable_bytes:([$items[] | select(.protected == false) | .size_bytes // 0] | add // 0),
      protected_bytes:([$items[] | select(.protected == true) | .size_bytes // 0] | add // 0)}'
}

# ------------------------------------------------------- 1. skill worktrees

group_worktrees() {
  local runs items='[]' entry skill key run_id lock wt state size holders safe_json cls prot reason
  runs=$("$run_lock" list 2>/dev/null || printf '{"runs":[]}')
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    skill=$(printf '%s' "$entry" | jq -r '.skill')
    key=$(printf '%s' "$entry" | jq -r '.key')
    run_id=$(printf '%s' "$entry" | jq -r '.run_id')
    lock=$(printf '%s' "$entry" | jq -r '.lock')
    state=$(printf '%s' "$entry" | jq -r '.state')
    wt=$(printf '%s' "$entry" | jq -r '.worktree // ""')
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    size=$(size_bytes "$wt")
    holders=$(holders_of "$wt" | awk 'NF' | head -n 5 | tr '\n' ' ')
    safe_json=$("$run_lock" safe "$wt" 2>/dev/null || true)
    if [ -z "$safe_json" ]; then safe_json='{"safe":false,"reasons":["could not be evaluated"]}'; fi

    if [ "$lock" = live ]; then
      cls='in use'; prot=true
      reason="owned by a live $skill run on $key"
    elif [ "$state" = retained ] || [ "$(printf '%s' "$safe_json" | jq -r '.safe')" != true ]; then
      cls='holds work'; prot=true
      reason="unsaved work: $(printf '%s' "$safe_json" | jq -r '.reasons | join("; ")')"
    elif [ -n "$holders" ]; then
      cls=unknown; prot=true
      reason="lease expired but process(es) $holders still hold the path"
    elif [ "$DETECTION_AVAILABLE" != true ]; then
      cls=unknown; prot=true
      reason="lease expired but this machine offers no way to prove no process holds the path"
    else
      cls=stale; prot=false
      reason="lease past its time-to-live, nothing unsaved, no process holding the path"
    fi
    items=$(jq -nc --argjson a "$items" --argjson i "$(item \
      "worktree:$wt" "$wt" "$size" "$cls" "$prot" "$reason" "$skill" "$run_id" "$key" \
      "$(printf '%s' "$safe_json" | jq -r '.reasons | join("; ")')" \
      "$(if [ "$cls" = 'holds work' ]; then printf '%s' "$skill"; fi)" \
      "$(if [ "$prot" = false ]; then printf 'reclaim.sh --item worktree:%s' "$wt"; fi)")" '$a + [$i]')
  done <<EOF
$(printf '%s' "$runs" | jq -c '.runs[]?')
EOF
  group skill-worktrees "Skill worktrees and managed clones" inventoried "" "$items"
}

# ------------------------------------------------------- 2. git artifacts

group_git() {
  local items='[]' size branch default
  if ! git -C "$PROJECT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    group git-artifacts "Git artifacts in the project" skipped "not a git working tree" '[]'
    return 0
  fi
  local gitdir
  gitdir=$(git -C "$PROJECT" rev-parse --git-dir)
  case $gitdir in /*) ;; *) gitdir=$PROJECT/$gitdir ;; esac
  size=$(size_bytes "$gitdir/objects")
  items=$(jq -nc --argjson a "$items" --argjson i "$(item \
    "git-objects:$gitdir/objects" "$gitdir/objects" "$size" unknown true \
    "repository object storage is informational; garbage collection is the user's call, never inferred from a path" \
    "" "" "" "" "" "")" '$a + [$i]')

  local stale_regs
  stale_regs=$(git -C "$PROJECT" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' || true)
  while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    if [ ! -d "$branch" ]; then
      items=$(jq -nc --argjson a "$items" --argjson i "$(item \
        "git-worktree-registration:$branch" "$branch" "" orphan false \
        "worktree registration points at a path that no longer exists" "" "" "" "" "" \
        "git -C <project> worktree prune")" '$a + [$i]')
    fi
  done <<EOF
$stale_regs
EOF

  default=$(git -C "$PROJECT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || printf '')
  default=${default#origin/}
  if [ -n "$default" ]; then
    while IFS= read -r branch; do
      branch=${branch## }
      [ -n "$branch" ] || continue
      [ "$branch" != "$default" ] || continue
      items=$(jq -nc --argjson a "$items" --argjson i "$(item \
        "git-branch:$branch" "" "" unknown true \
        "local branch already merged into $default; user-created branches are informational unless named explicitly" \
        "" "" "" "" "" "")" '$a + [$i]')
    done <<EOF
$(git -C "$PROJECT" branch --merged "$default" --format '%(refname:short)' 2>/dev/null || true)
EOF
  fi
  group git-artifacts "Git artifacts in the project" inventoried "" "$items"
}

# --------------------------------------------------------- 3. kubernetes

group_kubernetes() {
  if ! have kubectl; then
    group kubernetes "Kubernetes" skipped "kubectl is not installed" '[]'
    return 0
  fi
  local context endpoint local_ctx=false items='[]' ns
  context=$(kubectl config current-context 2>/dev/null || printf '')
  if [ -z "$context" ]; then
    group kubernetes "Kubernetes" skipped "no current kubectl context" '[]'
    return 0
  fi
  endpoint=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || printf '')
  case $endpoint in
    https://127.0.0.1:* | https://localhost:* | https://0.0.0.0:* | https://192.168.* | https://10.*) local_ctx=true ;;
  esac
  if [ "$local_ctx" != true ]; then
    group kubernetes "Kubernetes" skipped \
      "context '$context' at '$endpoint' is not positively local and single-user; failing closed" '[]'
    return 0
  fi
  while IFS= read -r ns; do
    [ -n "$ns" ] || continue
    local skill run_id
    skill=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.team-agent-skill}' 2>/dev/null || printf '')
    run_id=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.team-agent-run}' 2>/dev/null || printf '')
    if [ -z "$skill" ] || [ -z "$run_id" ]; then continue; fi
    local lock='free'
    lock=$("$run_lock" list "$skill" 2>/dev/null | jq -r --arg r "$run_id" \
      '[.runs[]? | select(.run_id == $r) | .lock] | first // "free"')
    if [ "$lock" = live ]; then
      items=$(jq -nc --argjson a "$items" --argjson i "$(item \
        "k8s-namespace:$ns" "" "" 'in use' true "created by a live $skill run" "$skill" "$run_id" "" "" "" "")" '$a + [$i]')
    else
      items=$(jq -nc --argjson a "$items" --argjson i "$(item \
        "k8s-namespace:$ns" "" "" orphan false \
        "namespace carries this skill family's ownership labels and its run is no longer live" \
        "$skill" "$run_id" "" "" "" "reclaim.sh --item k8s-namespace:$ns")" '$a + [$i]')
    fi
  done <<EOF
$(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
EOF
  group kubernetes "Kubernetes" inventoried "" "$items"
}

# ------------------------------------------------- 4. images and caches

group_images() {
  local runtime='' items='[]' line
  if have docker; then runtime=docker; elif have podman; then runtime=podman; fi
  if [ -z "$runtime" ]; then
    group container-images "Container images and build caches" skipped "no container runtime found" '[]'
    return 0
  fi
  if ! "$runtime" info >/dev/null 2>&1; then
    group container-images "Container images and build caches" skipped "$runtime is installed but not running" '[]'
    return 0
  fi
  while IFS='|' read -r id repo size; do
    [ -n "$id" ] || continue
    items=$(jq -nc --argjson a "$items" --argjson i "$(item \
      "image:$id" "" "" orphan false "image carries this skill family's ownership labels ($repo, $size)" \
      "" "" "" "" "" "reclaim.sh --item image:$id")" '$a + [$i]')
  done <<EOF
$("$runtime" images --filter 'label=team-agent-skill' --format '{{.ID}}|{{.Repository}}:{{.Tag}}|{{.Size}}' 2>/dev/null || true)
EOF
  items=$(jq -nc --argjson a "$items" --argjson i "$(item \
    "builder-cache:$runtime" "" "" unknown true \
    "builder cache is shared with everything else on this machine; a global prune is never invoked" \
    "" "" "" "" "" "")" '$a + [$i]')
  group container-images "Container images and build caches" inventoried "" "$items"
}

# ----------------------------------------------- 5. dependency and build

group_dependencies() {
  local items='[]' root roots dir size holders cls prot reason
  roots=$PROJECT
  local runs wt
  runs=$("$run_lock" list 2>/dev/null || printf '{"runs":[]}')
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    [ -d "$wt" ] || continue
    roots="$roots
$wt"
  done <<EOF
$(printf '%s' "$runs" | jq -r '.runs[]?.worktree // empty')
EOF

  while IFS= read -r root; do
    [ -n "$root" ] || continue
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      size=$(size_bytes "$dir")
      holders=$(holders_of "$dir" | awk 'NF' | head -n 3 | tr '\n' ' ')
      if [ -n "$holders" ]; then
        cls='in use'; prot=true; reason="process(es) $holders hold this path open"
      elif [ "$DETECTION_AVAILABLE" != true ]; then
        cls=unknown; prot=true; reason="cannot prove no process is using it on this machine"
      else
        cls=orphan; prot=false; reason="regenerable build or dependency output inside the named project"
      fi
      items=$(jq -nc --argjson a "$items" --argjson i "$(item \
        "dependency:$dir" "$dir" "$size" "$cls" "$prot" "$reason" "" "" "" "" "" \
        "$(if [ "$prot" = false ]; then printf 'reclaim.sh --item dependency:%s' "$dir"; fi)")" '$a + [$i]')
    done <<EOF
$(find "$root" -maxdepth 3 \( -name node_modules -o -name .venv -o -name venv -o -name dist \
    -o -name build -o -name target -o -name coverage -o -name .pytest_cache \) \
    -prune -type d 2>/dev/null || true)
EOF
  done <<EOF
$roots
EOF
  group dependencies "Project dependency and build output" inventoried "" "$items"
}

# --------------------------------------------------- 6. skill state and logs

group_state() {
  local root items='[]' dir size run_id lock
  root=$("$run_lock" list 2>/dev/null | jq -r '.state_root // empty')
  if [ -z "$root" ]; then
    group skill-state "Skill state, scratch, and logs" skipped "no skill state directory" '[]'
    return 0
  fi
  items=$(jq -nc --argjson a "$items" --argjson i "$(item \
    "config:$root/config" "$root/config" "$(size_bytes "$root/config")" unknown true \
    "saved identities, project conventions, and configuration are always protected" "" "" "" "" "" "")" '$a + [$i]')
  for dir in "$root"/tmp/*; do
    [ -d "$dir" ] || continue
    run_id=$(basename -- "$dir")
    size=$(size_bytes "$dir")
    lock=$("$run_lock" list 2>/dev/null | jq -r --arg r "$run_id" \
      '[.runs[]? | select(.run_id == $r) | .lock] | first // "none"')
    if [ "$lock" = live ]; then
      items=$(jq -nc --argjson a "$items" --argjson i "$(item \
        "tmp:$dir" "$dir" "$size" 'in use' true "scratch directory of a live run" "" "$run_id" "" "" "" "")" '$a + [$i]')
    else
      items=$(jq -nc --argjson a "$items" --argjson i "$(item \
        "tmp:$dir" "$dir" "$size" orphan false "run-keyed scratch directory whose run is no longer live" \
        "" "$run_id" "" "" "" "reclaim.sh --item tmp:$dir")" '$a + [$i]')
    fi
  done
  group skill-state "Skill state, scratch, and logs" inventoried "" "$items"
}

# ------------------------------------------------------- 7. processes

group_processes() {
  local items='[]' pid cmd cwd link
  if [ ! -d /proc ]; then
    group processes "Processes and ports" skipped "no process table available to attribute reliably" '[]'
    return 0
  fi
  for link in /proc/[0-9]*; do
    pid=${link#/proc/}
    cwd=$(readlink -f "$link/cwd" 2>/dev/null || printf '')
    case $cwd in
      "$PROJECT" | "$PROJECT"/*) ;;
      *) continue ;;
    esac
    cmd=$(tr '\0' ' ' < "$link/cmdline" 2>/dev/null | cut -c1-120 || printf '')
    [ -n "$cmd" ] || continue
    items=$(jq -nc --argjson a "$items" --argjson i "$(item \
      "process:$pid" "$cwd" "" unknown true \
      "running in the project but not attributable to a registered skill run: $cmd" "" "" "" "" "" "")" '$a + [$i]')
  done
  group processes "Processes and ports" inventoried "" "$items"
}

main() {
  need jq
  need git
  [ -x "$run_lock" ] || die "run_lock.sh is missing or not executable beside this script"
  while [ $# -gt 0 ]; do
    case $1 in
      --project) PROJECT=${2:?--project needs a value}; shift 2 ;;
      --format) FORMAT=${2:?--format needs a value}; shift 2 ;;
      -h | --help) usage; return 0 ;;
      *) die "unexpected argument: $1" ;;
    esac
  done
  [ "$FORMAT" = json ] || die "--format supports json only"
  [ -d "$PROJECT" ] || die "project path not found: $PROJECT"
  PROJECT=$(cd -- "$PROJECT" && pwd -P)

  local groups state_root
  state_root=$("$run_lock" list 2>/dev/null | jq -r '.state_root // ""')
  groups=$(jq -nc \
    --argjson a "$(group_worktrees)" --argjson b "$(group_git)" \
    --argjson c "$(group_kubernetes)" --argjson d "$(group_images)" \
    --argjson e "$(group_dependencies)" --argjson f "$(group_state)" \
    --argjson g "$(group_processes)" '[$a,$b,$c,$d,$e,$f,$g]')

  jq -nc --argjson schema_version "$SCHEMA_VERSION" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg project "$PROJECT" --arg state_root "$state_root" \
    --argjson groups "$groups" \
    '{schema_version:$schema_version, generated_at:$generated_at, project:$project,
      state_root:$state_root,
      awareness:{registry_covers:["create-clarity","implement","watch-and-fix","watch-and-review","manual-qa","clean-memory"],
        note:"Liveness is read from this skill family'"'"'s own run registry. Another agent, another runtime, another user account, or a developer'"'"'s own editor holding a checkout is invisible to it and reaches this report only through the process and open-file checks."},
      groups:$groups,
      totals:{reclaimable_bytes:([$groups[].reclaimable_bytes // 0]|add // 0),
              protected_bytes:([$groups[].protected_bytes // 0]|add // 0),
              unmeasured_items:([$groups[].items[] | select(.size_measured == false)]|length)}}'
}

main "$@"
