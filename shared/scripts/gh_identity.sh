#!/usr/bin/env bash
# shared-component: gh_identity.sh v2 sha256=d49f2792721b1c771d302cac21dfd8e451898ccc6dff0498d23e6947a6935852
# Resolve which authenticated GitHub account acts on a target, then run exactly one
# gh command (or one narrowly validated git push) with that account's credentials,
# supplied per invocation and never written to disk.
set -euo pipefail

prog=${0##*/}
SCHEMA_VERSION=1

die() { printf '%s: %s\n' "$prog" "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

usage() {
  cat <<'EOF'
gh_identity.sh list
gh_identity.sh get TARGET
gh_identity.sh set LOGIN
gh_identity.sh select [--need read|comment|write|push] TARGET
gh_identity.sh exec [--user LOGIN] [--need read|comment|write|push] TARGET -- gh ARGS...
gh_identity.sh git-push [--user LOGIN] TARGET --repo OWNER/REPOSITORY \
  --remote-url HTTPS_URL --source LOCAL_REF --dest refs/heads/BRANCH [--force-with-lease SHA]

TARGET is an issue or pull-request URL, OWNER/REPOSITORY#NUMBER, or OWNER/REPOSITORY.
Selection order: the repository's configured login, then the last login that worked for
this exact target, then capability probing across the remaining authenticated logins.
The workflow is never interrupted to ask which account to use.
EOF
}

# ------------------------------------------------------------------- state

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
  if [ ! -d "$root/config" ]; then (umask 077 && mkdir -p "$root/config"); fi
  if [ -L "$root" ] || [ -L "$root/config" ]; then die "refusing symlinked state path: $root"; fi
  local perm
  perm=$(stat -c '%a' "$root/config" 2>/dev/null || stat -f '%Lp' "$root/config" 2>/dev/null || printf '700')
  perm=${perm: -3}
  case ${perm:1:1}${perm:2:1} in
    *[2367]*) die "refusing group- or world-writable state path: $root/config ($perm)" ;;
  esac
  (cd -- "$root" && pwd -P)
}

identities_file() { printf '%s/config/identities.json' "$1"; }
projects_file() { printf '%s/config/projects.json' "$1"; }

read_json() {
  local path=$1 version
  if [ ! -f "$path" ]; then return 1; fi
  if [ -L "$path" ]; then die "refusing symlinked configuration file: $path"; fi
  if ! jq -e . "$path" >/dev/null 2>&1; then die "corrupt JSON document: $path"; fi
  version=$(jq -r '.schema_version // 1' "$path")
  if [ "$version" -gt "$SCHEMA_VERSION" ] 2>/dev/null; then
    die "document $path declares schema_version $version, newer than $SCHEMA_VERSION; refusing to interpret it"
  fi
  cat "$path"
}

write_identities() {
  local root=$1 body=$2 file tmp
  file=$(identities_file "$root")
  tmp=$file.tmp.$$
  (umask 077 && printf '%s\n' "$body" > "$tmp")
  mv -f "$tmp" "$file"
  chmod 600 "$file" 2>/dev/null || true
}

load_identities() {
  local root=$1
  read_json "$(identities_file "$root")" 2>/dev/null || \
    printf '{"schema_version":1,"kind":"identities","targets":{}}'
}

# ------------------------------------------------------------------ targets

TARGET_OWNER=''
TARGET_REPO=''
TARGET_NUMBER=''
TARGET_KEY=''

parse_target() {
  local raw=$1 rest
  case $raw in
    https://github.com/*)
      rest=${raw#https://github.com/}
      rest=${rest%%\?*}
      rest=${rest%/}
      TARGET_OWNER=${rest%%/*}; rest=${rest#*/}
      TARGET_REPO=${rest%%/*}; rest=${rest#"$TARGET_REPO"}
      case $rest in
        /issues/*) TARGET_NUMBER=${rest#/issues/} ;;
        /pull/*) TARGET_NUMBER=${rest#/pull/} ;;
        *) TARGET_NUMBER='' ;;
      esac
      TARGET_NUMBER=${TARGET_NUMBER%%/*}
      ;;
    *\#*)
      TARGET_NUMBER=${raw##*\#}
      rest=${raw%%\#*}
      TARGET_OWNER=${rest%%/*}
      TARGET_REPO=${rest#*/}
      ;;
    */*)
      TARGET_OWNER=${raw%%/*}
      TARGET_REPO=${raw#*/}
      TARGET_NUMBER=''
      ;;
    *) die "unrecognized target: '$raw'" ;;
  esac

  local re='^[A-Za-z0-9._-]+$'
  if ! printf '%s' "$TARGET_OWNER" | LC_ALL=C grep -qE "$re"; then die "invalid owner in target: '$raw'"; fi
  if ! printf '%s' "$TARGET_REPO" | LC_ALL=C grep -qE "$re"; then die "invalid repository in target: '$raw'"; fi
  if [ -n "$TARGET_NUMBER" ]; then
    if ! printf '%s' "$TARGET_NUMBER" | LC_ALL=C grep -qE '^[0-9]+$'; then
      die "invalid number in target: '$raw'"
    fi
    TARGET_KEY="$TARGET_OWNER/$TARGET_REPO#$TARGET_NUMBER"
  else
    TARGET_KEY="$TARGET_OWNER/$TARGET_REPO"
  fi
}

# ------------------------------------------------------------------ logins

authenticated_logins() {
  # Read the CLI's own account list. Both the current and the older status wording
  # are recognized so the helper is not tied to one CLI release.
  gh auth status 2>&1 | sed -n \
    -e 's/.*[Ll]ogged in to github\.com account \([A-Za-z0-9][A-Za-z0-9_-]*\).*/\1/p' \
    -e 's/.*[Ll]ogged in to github\.com as \([A-Za-z0-9][A-Za-z0-9_-]*\).*/\1/p' \
    | awk 'NF && !seen[$0]++'
}

token_for() {
  local login=$1 token
  token=$(gh auth token --user "$login" 2>/dev/null || printf '')
  if [ -z "$token" ]; then return 1; fi
  printf '%s' "$token"
}

verified_login_of() {
  local token=$1 seen
  seen=$(GH_TOKEN=$token GITHUB_TOKEN=$token GH_HOST=github.com \
    gh api user --jq '.login' 2>/dev/null || printf '')
  if [ -z "$seen" ]; then return 1; fi
  printf '%s' "$seen"
}

gh_as() {
  local token=$1; shift
  GH_TOKEN=$token GITHUB_TOKEN=$token GH_HOST=github.com "$@"
}

API_FAILURE=''

api_unreachable() {
  # api_unreachable TOKEN -> 0 when api.github.com itself is failing (network
  # error, timeout, 5xx), 1 when the API answered -- a 4xx here means any
  # credential problem is real. /rate_limit is the cheapest possible probe.
  local token=$1 err
  API_FAILURE=''
  if err=$(gh_as "$token" gh api rate_limit 2>&1 >/dev/null); then return 1; fi
  case $err in
    *'HTTP 4'[0-9][0-9]*) return 1 ;;
  esac
  API_FAILURE=${err%%$'\n'*}
  return 0
}

die_api_unreachable() {
  # Exit 4 is distinct from usage/validation errors (2) and selection failure (1).
  printf '%s: GitHub API unreachable or erroring (%s) — not a credential problem; saved logins are untouched, retry once GitHub recovers\n' \
    "$prog" "${API_FAILURE:-no response}" >&2
  exit 4
}

# ---------------------------------------------------------------- probing

PROBE_REASON=''

probe_capability() {
  # probe_capability TOKEN CAPABILITY -> 0 satisfied, 1 not satisfied, 3 unknown
  local token=$1 need=$2 repo_json issue_json archived push pull locked
  PROBE_REASON=''
  repo_json=$(gh_as "$token" gh api "repos/$TARGET_OWNER/$TARGET_REPO" 2>/dev/null || printf '')
  if [ -z "$repo_json" ]; then PROBE_REASON="cannot read repository metadata"; return 1; fi

  if [ -n "$TARGET_NUMBER" ]; then
    issue_json=$(gh_as "$token" gh api "repos/$TARGET_OWNER/$TARGET_REPO/issues/$TARGET_NUMBER" 2>/dev/null || printf '')
    if [ -z "$issue_json" ]; then PROBE_REASON="cannot read target metadata"; return 1; fi
  else
    issue_json='{}'
  fi

  case $need in
    read) return 0 ;;
  esac

  archived=$(printf '%s' "$repo_json" | jq -r '.archived // false')
  push=$(printf '%s' "$repo_json" | jq -r '.permissions.push // false')
  pull=$(printf '%s' "$repo_json" | jq -r '.permissions.pull // false')
  locked=$(printf '%s' "$issue_json" | jq -r '.locked // false')

  case $need in
    comment)
      if [ "$archived" = true ]; then PROBE_REASON="repository is archived"; return 1; fi
      if [ "$locked" = true ]; then PROBE_REASON="target is locked"; return 1; fi
      if [ "$pull" != true ] && [ "$push" != true ]; then
        PROBE_REASON="no read permission reported"; return 1
      fi
      if [ "$(printf '%s' "$repo_json" | jq -r 'has("permissions")')" != true ]; then
        PROBE_REASON="permissions not visible; capability unknown"; return 3
      fi
      return 0
      ;;
    write | push)
      if [ "$archived" = true ]; then PROBE_REASON="repository is archived"; return 1; fi
      if [ "$(printf '%s' "$repo_json" | jq -r 'has("permissions")')" != true ]; then
        PROBE_REASON="permissions not visible; capability unknown"; return 3
      fi
      if [ "$push" = true ]; then return 0; fi
      PROBE_REASON="login lacks push permission on the repository"
      return 1
      ;;
    *) die "unknown capability: $need" ;;
  esac
}

configured_login() {
  local root=$1 projects
  projects=$(read_json "$(projects_file "$root")" 2>/dev/null || printf '')
  if [ -z "$projects" ]; then return 1; fi
  printf '%s' "$projects" | jq -r --arg k "$TARGET_OWNER/$TARGET_REPO" \
    '.projects[$k].github_login // empty'
}

saved_login() {
  local root=$1
  load_identities "$root" | jq -r --arg k "$TARGET_KEY" '.targets[$k].login // empty'
}

save_login() {
  local root=$1 login=$2 capability=$3 body
  body=$(load_identities "$root" | jq -c --arg k "$TARGET_KEY" --arg l "$login" \
    --arg c "$capability" --argjson t "$(date +%s)" \
    '.schema_version = 1 | .kind = "identities"
     | .targets[$k] = {login:$l, capability:$c, verified_at:$t}')
  write_identities "$root" "$body"
}

SELECTED_LOGIN=''
SELECTED_TOKEN=''
SELECTED_WHY=''
SELECTED_CAPABILITY=''

select_identity() {
  # select_identity NEED [FORCED_LOGIN]
  local need=$1 forced=${2:-} root candidates login token verified rc
  root=$(state_root)
  SELECTED_LOGIN=''; SELECTED_TOKEN=''; SELECTED_WHY=''; SELECTED_CAPABILITY=$need

  local ordered='' first second attempted=''
  if [ -n "$forced" ]; then
    ordered=$forced
  else
    first=$(configured_login "$root" || printf '')
    second=$(saved_login "$root" || printf '')
    candidates=$(authenticated_logins || printf '')
    ordered=$(printf '%s\n%s\n%s\n' "$first" "$second" "$candidates" | awk 'NF && !seen[$0]++')
  fi

  while IFS= read -r login; do
    [ -n "$login" ] || continue
    attempted="$attempted $login"
    if ! token=$(token_for "$login"); then
      continue
    fi
    if ! verified=$(verified_login_of "$token"); then
      if api_unreachable "$token"; then die_api_unreachable; fi
      continue
    fi
    if [ "$verified" != "$login" ]; then
      continue
    fi
    set +e
    probe_capability "$token" "$need"
    rc=$?
    set -e
    if [ "$rc" = 0 ] || [ "$rc" = 3 ]; then
      SELECTED_LOGIN=$login
      SELECTED_TOKEN=$token
      if [ -n "$forced" ]; then
        SELECTED_WHY="explicit per-invocation override"
      elif [ "$login" = "$first" ]; then
        SELECTED_WHY="configured github_login for this repository"
      elif [ "$login" = "$second" ]; then
        SELECTED_WHY="last login that succeeded for this target"
      else
        SELECTED_WHY="capability probing across authenticated logins"
      fi
      if [ "$rc" = 3 ]; then
        SELECTED_WHY="$SELECTED_WHY (capability unknown: $PROBE_REASON)"
      fi
      return 0
    fi
  done <<EOF
$ordered
EOF

  printf '%s: no authenticated account satisfies "%s" for %s. attempted:%s (last reason: %s)\n' \
    "$prog" "$need" "$TARGET_KEY" "${attempted:- none}" "${PROBE_REASON:-no credential}" >&2
  return 1
}

# ----------------------------------------------------------------- commands

cmd_list() {
  local root logins out='[]' login preferred
  root=$(state_root)
  logins=$(authenticated_logins || printf '')
  preferred=$(load_identities "$root" | jq -r '.preferred_login // empty')
  while IFS= read -r login; do
    [ -n "$login" ] || continue
    out=$(jq -nc --argjson a "$out" --arg l "$login" '$a + [$l]')
  done <<EOF
$logins
EOF
  jq -nc --argjson logins "$out" --arg preferred "$preferred" \
    --argjson targets "$(load_identities "$root" | jq -c '.targets')" \
    '{authenticated:$logins, preferred_login:(if $preferred=="" then null else $preferred end),
      saved_targets:$targets}'
}

cmd_get() {
  local root
  parse_target "${1:?get requires a target}"
  root=$(state_root)
  jq -nc --arg target "$TARGET_KEY" \
    --arg configured "$(configured_login "$root" || printf '')" \
    --arg saved "$(saved_login "$root" || printf '')" \
    '{target:$target,
      configured_login:(if $configured=="" then null else $configured end),
      saved_login:(if $saved=="" then null else $saved end)}'
}

cmd_set() {
  local login=${1:?set requires a login} root token verified body
  if ! printf '%s' "$login" | LC_ALL=C grep -qE '^[A-Za-z0-9][A-Za-z0-9_-]*$'; then
    die "invalid login: '$login'"
  fi
  root=$(state_root)
  token=$(token_for "$login") || die "no per-invocation credential available for '$login'"
  if ! verified=$(verified_login_of "$token"); then
    if api_unreachable "$token"; then die_api_unreachable; fi
    die "credential for '$login' could not be verified"
  fi
  [ "$verified" = "$login" ] || die "credential for '$login' authenticates as '$verified'"
  body=$(load_identities "$root" | jq -c --arg l "$login" \
    '.schema_version = 1 | .kind = "identities" | .preferred_login = $l')
  write_identities "$root" "$body"
  jq -nc --arg l "$login" \
    '{result:"set", preferred_login:$l,
      note:"preferred first candidate only; it makes no claim about access to any future target"}'
}

cmd_select() {
  local need=read target=''
  while [ $# -gt 0 ]; do
    case $1 in
      --need) need=${2:?--need needs a value}; shift 2 ;;
      --) shift ;;
      -*) die "unexpected option: $1" ;;
      *) target=$1; shift ;;
    esac
  done
  [ -n "$target" ] || die "select requires a target"
  parse_target "$target"
  select_identity "$need" || exit 1
  save_login "$(state_root)" "$SELECTED_LOGIN" "$need"
  jq -nc --arg login "$SELECTED_LOGIN" --arg why "$SELECTED_WHY" \
    --arg target "$TARGET_KEY" --arg need "$need" \
    '{login:$login, target:$target, capability:$need, reason:$why}'
}

cmd_exec() {
  local need=read user='' target=''
  while [ $# -gt 0 ]; do
    case $1 in
      --need) need=${2:?--need needs a value}; shift 2 ;;
      --user) user=${2:?--user needs a value}; shift 2 ;;
      --) shift; break ;;
      -*) die "unexpected option: $1" ;;
      *) target=$1; shift ;;
    esac
  done
  [ -n "$target" ] || die "exec requires a target"
  [ $# -gt 0 ] || die "exec requires a command after --"
  [ "$1" = gh ] || die "exec runs only a gh command, got '$1'"
  parse_target "$target"
  select_identity "$need" "$user" || exit 1
  if [ -z "$user" ]; then save_login "$(state_root)" "$SELECTED_LOGIN" "$need"; fi
  printf '%s: acting as GitHub %s on %s (%s)\n' "$prog" "@$SELECTED_LOGIN" "$TARGET_KEY" "$SELECTED_WHY" >&2
  gh_as "$SELECTED_TOKEN" "$@"
}

cmd_git_push() {
  local user='' target='' repo='' remote_url='' source_ref='' dest='' lease=''
  while [ $# -gt 0 ]; do
    case $1 in
      --user) user=${2:?--user needs a value}; shift 2 ;;
      --repo) repo=${2:?--repo needs a value}; shift 2 ;;
      --remote-url) remote_url=${2:?--remote-url needs a value}; shift 2 ;;
      --source) source_ref=${2:?--source needs a value}; shift 2 ;;
      --dest) dest=${2:?--dest needs a value}; shift 2 ;;
      --force-with-lease) lease=${2:?--force-with-lease needs a value}; shift 2 ;;
      --) shift ;;
      -*) die "unexpected option: $1" ;;
      *) target=$1; shift ;;
    esac
  done
  [ -n "$target" ] || die "git-push requires a target"
  [ -n "$repo" ] || die "git-push requires --repo"
  [ -n "$remote_url" ] || die "git-push requires --remote-url"
  [ -n "$source_ref" ] || die "git-push requires --source"
  [ -n "$dest" ] || die "git-push requires --dest"
  parse_target "$target"

  if ! printf '%s' "$repo" | LC_ALL=C grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    die "--repo must be OWNER/REPOSITORY"
  fi
  if [ "$remote_url" != "https://github.com/$repo.git" ]; then
    die "--remote-url must be the canonical https URL for $repo"
  fi
  case $dest in
    refs/heads/*) ;;
    *) die "--dest must be under refs/heads/" ;;
  esac
  case $dest in
    *:* | *' '* | *'*'*) die "--dest must name exactly one branch ref" ;;
  esac
  if [ "$dest" = "refs/heads/" ]; then die "--dest must name a branch"; fi
  case $source_ref in
    '' | :* | *:*) die "--source must be a single local ref" ;;
  esac
  if [ -n "$lease" ]; then
    if ! printf '%s' "$lease" | LC_ALL=C grep -qE '^[0-9a-f]{40}$'; then
      die "--force-with-lease requires a full 40-character SHA"
    fi
  fi

  local rewrites
  rewrites=$(git config --get-regexp '^url\..*\.insteadof$' 2>/dev/null || printf '')
  if [ -n "$rewrites" ]; then
    die "refusing to push while url.*.insteadOf rewrites are configured"
  fi

  local login token
  if [ -n "$user" ]; then
    login=$user
    token=$(token_for "$login") || die "no per-invocation credential available for '$login'"
    local verified
    if ! verified=$(verified_login_of "$token"); then
      if api_unreachable "$token"; then die_api_unreachable; fi
      die "credential for '$login' could not be verified"
    fi
    [ "$verified" = "$login" ] || die "credential for '$login' authenticates as '$verified'"
  else
    select_identity push || exit 1
    login=$SELECTED_LOGIN
    token=$SELECTED_TOKEN
  fi

  local askpass
  askpass=$(mktemp "${TMPDIR:-/tmp}/gh-askpass.XXXXXX")
  chmod 700 "$askpass"
  cleanup_askpass() { rm -f -- "$askpass"; }
  trap cleanup_askpass EXIT INT TERM HUP
  cat > "$askpass" <<'HELPER'
#!/usr/bin/env bash
case ${1:-} in
  Username*) printf '%s\n' "${GIT_PUSH_LOGIN:-}" ;;
  *) printf '%s\n' "${GIT_PUSH_TOKEN:-}" ;;
esac
HELPER

  local refspec="$source_ref:$dest" rc=0
  set +e
  if [ -n "$lease" ]; then
    GIT_ASKPASS=$askpass GIT_PUSH_LOGIN=$login GIT_PUSH_TOKEN=$token \
      GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      git -c credential.helper= push --no-verify \
      "--force-with-lease=$dest:$lease" "$remote_url" "$refspec"
    rc=$?
  else
    GIT_ASKPASS=$askpass GIT_PUSH_LOGIN=$login GIT_PUSH_TOKEN=$token \
      GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      git -c credential.helper= push --no-verify "$remote_url" "$refspec"
    rc=$?
  fi
  set -e
  cleanup_askpass
  trap - EXIT INT TERM HUP
  if [ "$rc" != 0 ]; then
    printf '%s: push failed (exit %s); a lease mismatch means someone else pushed — re-fetch and rebuild the change\n' \
      "$prog" "$rc" >&2
    return "$rc"
  fi
  jq -nc --arg login "$login" --arg repo "$repo" --arg dest "$dest" \
    '{result:"pushed", login:$login, repository:$repo, dest:$dest}'
}

# --------------------------------------------------------------------- main

main() {
  need jq
  need gh
  local sub=${1:-}
  if [ $# -gt 0 ]; then shift; fi
  case $sub in
    list) cmd_list "$@" ;;
    get) cmd_get "$@" ;;
    set) cmd_set "$@" ;;
    select) cmd_select "$@" ;;
    exec) cmd_exec "$@" ;;
    git-push) need git; cmd_git_push "$@" ;;
    -h | --help | help | '') usage ;;
    *) usage >&2; die "unknown subcommand: $sub" ;;
  esac
}

main "$@"
