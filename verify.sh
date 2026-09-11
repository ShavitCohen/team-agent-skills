#!/usr/bin/env bash
# verify.sh — mechanical package verification for the team-agent-skills packages.
#
# Usage: verify.sh PACKAGE_DIR [PACKAGE_DIR...]
#
# Implements the checks of the specification section "Mechanical package
# verification" (.spec-monolith.md): manifest, frontmatter, scripts,
# shared-component integrity, dangling references, forbidden operations,
# no-hardcoding, and offline tests. It only reports; it never modifies a
# package. Every failure across every supplied package is printed, then the
# script exits non-zero if any check failed anywhere.
#
# Dependencies: bash, coreutils (sha256sum, timeout, find, sort, wc, ...),
# grep/sed/awk. python3 (with PyYAML if present) is used opportunistically for
# strict YAML frontmatter parsing; without it a lenient parser still runs.
# `unshare -rn` is used for network-denied test runs when available.

set -euo pipefail

prog=${0##*/}

if [ "$#" -lt 1 ]; then
  printf 'usage: %s PACKAGE_DIR [PACKAGE_DIR...]\n' "$prog" >&2
  exit 2
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/verify.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

# ---------------------------------------------------------------- manifests
# Authoritative per-package file sets from the specification. Key: basename.
declare -A MANIFEST

MANIFEST[clean-memory]='SKILL.md references/policy/browser.md references/policy/conventions.md references/policy/handoff.md references/policy/trust.md references/policy/worktrees.md schemas/cases-v1.json schemas/inventory-v1.json schemas/shared-state-v1.json scripts/inventory.sh scripts/reclaim.sh scripts/run_lock.sh tests/fixtures/cases.json tests/validate.sh'
MANIFEST[create-clarity]='SKILL.md references/policy/conventions.md references/policy/handoff.md references/policy/identity.md references/policy/trust.md references/policy/worktrees.md schemas/cases-v1.json schemas/shared-state-v1.json scripts/gh_identity.sh scripts/run_lock.sh tests/fixtures/cases.json tests/validate.sh'
MANIFEST[implement]='SKILL.md references/gh-commands.md references/worker-brief.md references/policy/browser.md references/policy/conventions.md references/policy/handoff.md references/policy/identity.md references/policy/pr-lifecycle.md references/policy/trust.md references/policy/worktrees.md schemas/cases-v1.json schemas/shared-state-v1.json scripts/gh_identity.sh scripts/run_lock.sh tests/fixtures/cases.json tests/validate.sh'
MANIFEST[manual-qa]='SKILL.md references/comment-format.md references/policy/identity.md references/policy/trust.md schemas/cases-v1.json schemas/shared-state-v1.json scripts/gh_identity.sh scripts/k8s_preflight.py scripts/run_lock.sh tests/fixtures/cases.json tests/validate.sh'
MANIFEST[orchestrate]='SKILL.md references/lanes.md references/stage-briefs.md references/policy/conventions.md references/policy/handoff.md references/policy/identity.md references/policy/polling.md references/policy/trust.md references/policy/worktrees.md schemas/cases-v1.json schemas/orchestrate-profile-v1.json schemas/orchestrate-run-v1.json schemas/poll-snapshot-v1.json schemas/shared-state-v1.json scripts/gh_identity.sh scripts/lane_profile.sh scripts/poll_pr.sh scripts/run_lock.sh scripts/stage_signal.sh tests/fixtures/cases.json tests/validate.sh'
MANIFEST[pr-fix]='SKILL.md references/gh-commands.md references/policy/browser.md references/policy/conventions.md references/policy/handoff.md references/policy/identity.md references/policy/polling.md references/policy/pr-lifecycle.md references/policy/trust.md references/policy/worktrees.md schemas/cases-v1.json schemas/poll-snapshot-v1.json schemas/shared-state-v1.json scripts/gh_identity.sh scripts/poll_pr.sh scripts/run_lock.sh tests/fixtures/cases.json tests/validate.sh'
MANIFEST[pr-review]=${MANIFEST[pr-fix]}
MANIFEST[tickets]='SKILL.md references/output-format.md references/query-language.md references/policy/trust.md scripts/fetch_tickets.sh tests/fixtures/queries.json tests/validate.sh'
MANIFEST[watch-and-fix]='SKILL.md references/policy/conventions.md references/policy/handoff.md references/policy/identity.md references/policy/polling.md references/policy/trust.md references/policy/worktrees.md schemas/cases-v1.json schemas/poll-snapshot-v1.json schemas/shared-state-v1.json scripts/gh_identity.sh scripts/poll_pr.sh scripts/run_lock.sh tests/fixtures/cases.json tests/validate.sh'
MANIFEST[watch-and-review]=${MANIFEST[watch-and-fix]}

# Shared components whose copies must be byte-identical across packages and
# must carry a provenance header. Policy files are shared by basename.
SHARED_SCRIPTS='gh_identity.sh run_lock.sh poll_pr.sh'
SHARED_SCHEMAS='cases-v1.json shared-state-v1.json poll-snapshot-v1.json'

# ------------------------------------------------------------------ reporting
declare -A PKG_FAILS PKG_INFOS
TOTAL_FAILS=0
TOTAL_INFOS=0
PKG_ORDER=()

fail() { # fail PKG CHECK MESSAGE
  local pkg=$1 check=$2 msg=$3
  PKG_FAILS[$pkg]=$(( ${PKG_FAILS[$pkg]:-0} + 1 ))
  TOTAL_FAILS=$(( TOTAL_FAILS + 1 ))
  printf 'FAIL  [%s] %s: %s\n' "$pkg" "$check" "$msg"
}

info() { # info PKG CHECK MESSAGE
  local pkg=$1 check=$2 msg=$3
  PKG_INFOS[$pkg]=$(( ${PKG_INFOS[$pkg]:-0} + 1 ))
  TOTAL_INFOS=$(( TOTAL_INFOS + 1 ))
  printf 'info  [%s] %s: %s\n' "$pkg" "$check" "$msg"
}

# Records for the cross-package byte-identity check: "component<TAB>hash<TAB>pkg"
COMP_RECORDS=()

# ------------------------------------------------------------------- helpers

sha_file() { sha256sum -- "$1" | awk '{print $1}'; }
sha_without_line() { sed "${2}d" -- "$1" | sha256sum | awk '{print $1}'; }

# Locate a provenance header. Prints "LINENO<TAB>DECLARED_HASH" or nothing.
provenance_header() {
  local f=$1 line=''
  case $f in
    *.sh)
      line=$(sed -n '2p' -- "$f")
      if printf '%s' "$line" | grep -qE '^# shared-component: [A-Za-z0-9._-]+ v[0-9]+ sha256=[0-9a-f]{64}$'; then
        printf '2\t%s\n' "$(printf '%s' "$line" | grep -oE 'sha256=[0-9a-f]{64}' | cut -d= -f2)"
      fi
      ;;
    *.md)
      line=$(sed -n '1p' -- "$f")
      if printf '%s' "$line" | grep -qE '^<!-- shared-component: [A-Za-z0-9._-]+ v[0-9]+ sha256=[0-9a-f]{64} -->$'; then
        printf '1\t%s\n' "$(printf '%s' "$line" | grep -oE 'sha256=[0-9a-f]{64}' | cut -d= -f2)"
      fi
      ;;
    *.json)
      local hit
      hit=$(grep -nE '^[[:space:]]*"\$comment": "shared-component: [A-Za-z0-9._-]+ v[0-9]+ sha256=[0-9a-f]{64}",?$' -- "$f" | head -1 || true)
      if [ -n "$hit" ]; then
        printf '%s\t%s\n' "${hit%%:*}" "$(printf '%s' "$hit" | grep -oE 'sha256=[0-9a-f]{64}' | cut -d= -f2)"
      fi
      ;;
  esac
}

# Does this line look like prose/data ABOUT a prohibition rather than a
# command invocation? (comment lines, grep/for-in scanning, "never do X" text)
prohibition_context() {
  printf '%s' "$1" | grep -qiE '^[[:space:]]*#|forbidden|never|must not|do not|don'\''t|grep|for[[:space:]]+[A-Za-z_]+[[:space:]]+in[[:space:]]'
}

# Split a markdown file into fenced-code lines and prose lines, each prefixed
# "LINENO:". Writes $scratch/fenced.txt and $scratch/prose.txt.
split_md_fences() {
  awk '
    /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
    { if (infence) print NR": "$0 > FENCED; else print NR": "$0 > PROSE }
  ' FENCED="$scratch/fenced.txt" PROSE="$scratch/prose.txt" "$1"
  : >> "$scratch/fenced.txt"; : >> "$scratch/prose.txt"
}

# ------------------------------------------------------------ check functions

check_manifest() {
  local pkg=$1 dir=$2 expected=$3 f rel
  declare -A want
  for f in $expected; do want[$f]=1; done

  for f in $expected; do
    [ -f "$dir/$f" ] || fail "$pkg" manifest "missing specified file: $f"
  done

  while IFS= read -r -d '' f; do
    rel=${f#"$dir"/}
    [ "$rel" = "agents/openai.yaml" ] && continue   # tolerated runtime metadata
    if [ -z "${want[$rel]:-}" ]; then
      case ${rel##*/} in
        [Rr][Ee][Aa][Dd][Mm][Ee]*|[Cc][Hh][Aa][Nn][Gg][Ee][Ll][Oo][Gg]*|[Ii][Nn][Ss][Tt][Aa][Ll][Ll]*)
          fail "$pkg" manifest "forbidden README/changelog/install file: $rel" ;;
        *)
          fail "$pkg" manifest "unspecified file present: $rel" ;;
      esac
    fi
  done < <(find "$dir" -type f -print0 | sort -z)
}

check_frontmatter() {
  local pkg=$1 dir=$2 skill=$2/SKILL.md
  [ -f "$skill" ] || { fail "$pkg" frontmatter "SKILL.md is missing"; return 0; }

  if [ "$(sed -n '1p' -- "$skill")" != '---' ]; then
    fail "$pkg" frontmatter "SKILL.md does not open with '---' YAML frontmatter"
    return 0
  fi

  # Frontmatter block (between the first and second '---' lines).
  awk 'NR==1{next} /^---[[:space:]]*$/{exit} {print}' "$skill" > "$scratch/fm.yaml"
  if ! grep -qE '^---[[:space:]]*$' <(sed -n '2,$p' -- "$skill"); then
    fail "$pkg" frontmatter "SKILL.md frontmatter is never closed by a second '---'"
    return 0
  fi

  # Lenient key/value extraction (used for structural checks and as fallback).
  local keys name desc words
  keys=$(grep -oE '^[A-Za-z0-9_-]+:' "$scratch/fm.yaml" | sed 's/:$//' | sort | tr '\n' ' ' || true)
  if [ "$(printf '%s' "$keys" | xargs 2>/dev/null || printf '%s' "$keys")" != "description name" ]; then
    fail "$pkg" frontmatter "frontmatter keys must be exactly 'name' and 'description', found: ${keys:-none}"
  fi

  name=$(sed -n 's/^name:[[:space:]]*//p' "$scratch/fm.yaml" | head -1 | sed 's/^["'\'']//; s/["'\'']$//')
  if [ "$name" != "$pkg" ]; then
    fail "$pkg" frontmatter "frontmatter name '$name' does not match directory basename '$pkg'"
  fi

  desc=$(sed -n 's/^description:[[:space:]]*//p' "$scratch/fm.yaml" | head -1 | sed 's/^["'\'']//; s/["'\'']$//')
  if [ -z "$desc" ]; then
    fail "$pkg" frontmatter "frontmatter has no description value"
  else
    words=$(printf '%s\n' "$desc" | wc -w)
    if [ "$words" -gt 50 ]; then
      fail "$pkg" frontmatter "description is $words words (maximum 50)"
    fi
  fi

  # Strict YAML parse when python3 + PyYAML are available. A frontmatter block
  # that a real YAML parser rejects will break skill loaders, so it fails.
  if command -v python3 >/dev/null 2>&1; then
    local pyout
    pyout=$(python3 - "$scratch/fm.yaml" <<'PYEOF' 2>&1 || true
import sys
try:
    import yaml
except ImportError:
    print("NOYAML"); sys.exit(0)
try:
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8").read())
except Exception as e:
    print("ERR " + " ".join(str(e).split())[:160]); sys.exit(0)
if not isinstance(d, dict):
    print("ERR frontmatter is not a YAML mapping"); sys.exit(0)
print("OK")
PYEOF
)
    case $pyout in
      OK) : ;;
      NOYAML) info "$pkg" frontmatter "python3 has no PyYAML; strict YAML parse skipped (lenient parse only)" ;;
      ERR*) fail "$pkg" frontmatter "frontmatter is not valid YAML under a strict parser: ${pyout#ERR }" ;;
      *) info "$pkg" frontmatter "strict YAML probe produced unexpected output: $pyout" ;;
    esac
  else
    info "$pkg" frontmatter "python3 unavailable; strict YAML parse skipped (lenient parse only)"
  fi
}

check_scripts() {
  local pkg=$1 dir=$2 f rel first err rc
  while IFS= read -r -d '' f; do
    rel=${f#"$dir"/}
    if ! err=$(bash -n -- "$f" 2>&1); then
      fail "$pkg" scripts "bash -n fails on $rel: $(printf '%s' "$err" | head -1)"
    fi
    [ -x "$f" ] || fail "$pkg" scripts "$rel is not executable"
    first=$(sed -n '1p' -- "$f")
    if [ "$first" != '#!/usr/bin/env bash' ]; then
      fail "$pkg" scripts "$rel first line is '$first', expected '#!/usr/bin/env bash'"
    fi
  done < <(find "$dir/scripts" "$dir/tests" -name '*.sh' -type f -print0 2>/dev/null | sort -z)

  while IFS= read -r -d '' f; do
    rel=${f#"$dir"/}
    first=$(sed -n '1p' -- "$f")
    if [ "$first" != '#!/usr/bin/env python3' ]; then
      fail "$pkg" scripts "$rel first line is '$first', expected '#!/usr/bin/env python3'"
    fi
    [ -x "$f" ] || fail "$pkg" scripts "$rel is not executable"
    rc=0
    timeout 30 "$f" --help > /dev/null 2> "$scratch/pyhelp.err" || rc=$?
    if [ "$rc" -ne 0 ]; then
      fail "$pkg" scripts "$rel --help exited $rc: $(head -1 "$scratch/pyhelp.err" 2>/dev/null || true)"
    fi
  done < <(find "$dir/scripts" -name '*.py' -type f -print0 2>/dev/null | sort -z)
}

check_shared_integrity() {
  local pkg=$1 dir=$2 f rel hdr lineno declared computed base compname
  while IFS= read -r -d '' f; do
    rel=${f#"$dir"/}
    base=${rel##*/}
    hdr=$(provenance_header "$f")

    # Which canonical shared component (if any) is this file a copy of?
    compname=''
    case $rel in
      references/policy/*.md) compname="references/policy/$base" ;;
      scripts/*)
        case " $SHARED_SCRIPTS " in *" $base "*) compname="scripts/$base" ;; esac ;;
      schemas/*)
        case " $SHARED_SCHEMAS " in *" $base "*) compname="schemas/$base" ;; esac ;;
    esac

    if [ -n "$hdr" ]; then
      lineno=${hdr%%$'\t'*}
      declared=${hdr#*$'\t'}
      computed=$(sha_without_line "$f" "$lineno")
      if [ "$computed" != "$declared" ]; then
        fail "$pkg" shared-integrity "$rel provenance hash mismatch: declared $declared, recomputed $computed"
      fi
    elif [ -n "$compname" ]; then
      fail "$pkg" shared-integrity "$rel is a shared component but carries no provenance header"
    fi

    if [ -n "$compname" ]; then
      COMP_RECORDS+=("$compname"$'\t'"$(sha_file "$f")"$'\t'"$pkg")
    fi
  done < <(find "$dir" -type f \( -name '*.sh' -o -name '*.md' -o -name '*.json' \) -print0 | sort -z)
}

check_dangling_refs() {
  local pkg=$1 dir=$2 f rel ref n
  # (a) no anchor links anywhere in any .md file
  while IFS= read -r -d '' f; do
    rel=${f#"$dir"/}
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      fail "$pkg" dangling-refs "$rel:$n contains a '](#...)' anchor link"
    done < <(grep -n '](#' -- "$f" | cut -d: -f1 || true)
  done < <(find "$dir" -name '*.md' -type f -print0 | sort -z)

  # (b) every package-relative path mentioned in SKILL.md and references/ resolves
  while IFS= read -r -d '' f; do
    rel=${f#"$dir"/}
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      if [ ! -e "$dir/$ref" ]; then
        fail "$pkg" dangling-refs "$rel mentions $ref, which does not exist in the package"
      fi
    done < <(grep -oE '(references/(policy/)?[A-Za-z0-9_-]+\.md|scripts/[A-Za-z0-9_-]+\.(sh|py)|schemas/[A-Za-z0-9_-]+\.json|tests/[A-Za-z0-9_/-]+\.(sh|json))' -- "$f" | sort -u || true)
  done < <(find "$dir/SKILL.md" "$dir/references" -name '*.md' -type f -print0 2>/dev/null | sort -z)
}

# Forbidden-operation patterns, applied per package.
forbidden_patterns() { # ARGS: pkg — prints "LABEL<TAB>ERE" lines
  local pkg=$1
  printf 'gh pr merge\tgh[[:space:]]+pr[[:space:]]+merge\n'
  printf 'auto-merge flag\tgh[[:space:]]+pr[^|;&]*--auto([^-A-Za-z0-9]|$)\n'
  printf 'merge endpoint\t(^|[^A-Za-z])mergePullRequest|/merge([^a-zA-Z-]|$)\n'
  printf 'approve invocation\t(^|[^A-Za-z])approvePullRequest|-f[[:space:]]+event=APPROVE|--approve([^-A-Za-z0-9]|$)\n'
  if [ "$pkg" != clean-memory ]; then
    printf 'literal-path rm -r\trm[[:space:]]+-[A-Za-z]*r[A-Za-z]*f?[A-Za-z]*[[:space:]]+(--[[:space:]]+)?["'\'']?(/|~)[A-Za-z0-9._/-]\n'
  fi
  if [ "$pkg" = pr-fix ]; then
    printf 'thread resolution\t(^|[^A-Za-z])resolveReviewThread\n'
  fi
}

check_forbidden() {
  local pkg=$1 dir=$2 f rel label ere hit line
  # Code files: scripts/**/*.sh|*.py and tests/**/*.sh — command context.
  while IFS= read -r -d '' f; do
    rel=${f#"$dir"/}
    while IFS=$'\t' read -r label ere; do
      [ -n "$label" ] || continue
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        line=${hit#*:}
        # The merge-endpoint '/merge' alternative only counts near an API call.
        if [ "$label" = 'merge endpoint' ] && ! printf '%s' "$line" | grep -qE 'mergePullRequest|gh[[:space:]]+api|graphql|curl'; then
          continue
        fi
        if prohibition_context "$line"; then
          info "$pkg" forbidden-ops "$rel:${hit%%:*} mentions '$label' in prose/data context (not an invocation): $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-90)"
        else
          fail "$pkg" forbidden-ops "$rel:${hit%%:*} contains forbidden operation ($label): $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-90)"
        fi
      done < <(grep -nE -- "$ere" "$f" || true)
    done < <(forbidden_patterns "$pkg")
  done < <(find "$dir/scripts" "$dir/tests" -type f \( -name '*.sh' -o -name '*.py' \) -print0 2>/dev/null | sort -z)

  # Markdown: imperative usage inside fenced code blocks fails; prose informs.
  while IFS= read -r -d '' f; do
    rel=${f#"$dir"/}
    split_md_fences "$f"
    while IFS=$'\t' read -r label ere; do
      [ -n "$label" ] || continue
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        line=${hit#*: }
        if [ "$label" = 'merge endpoint' ] && ! printf '%s' "$line" | grep -qE 'mergePullRequest|gh[[:space:]]+api|graphql|curl'; then
          continue
        fi
        fail "$pkg" forbidden-ops "$rel:${hit%%:*} fenced code block contains forbidden operation ($label): $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-90)"
      done < <(grep -nE -- "$ere" "$scratch/fenced.txt" | cut -d: -f2- || true)
      while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        line=${hit#*: }
        if [ "$label" = 'merge endpoint' ] && ! printf '%s' "$line" | grep -qE 'mergePullRequest|gh[[:space:]]+api|graphql|curl'; then
          continue
        fi
        info "$pkg" forbidden-ops "$rel:${hit%%:*} prose mentions '$label' (informational): $(printf '%s' "$line" | sed 's/^[[:space:]]*//' | cut -c1-90)"
      done < <(grep -nE -- "$ere" "$scratch/prose.txt" | cut -d: -f2- || true)
    done < <(forbidden_patterns "$pkg")
  done < <(find "$dir" -name '*.md' -type f -print0 | sort -z)
}

check_hardcoding() {
  local pkg=$1 dir=$2 f rel hit owner
  while IFS= read -r -d '' f; do
    rel=${f#"$dir"/}
    [ "$rel" = "agents/openai.yaml" ] && continue

    # Absolute home directories.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      fail "$pkg" hardcoding "$rel:${hit%%:*} hardcodes a home directory: $(printf '%s' "${hit#*:}" | cut -c1-90)"
    done < <(grep -nE '(/home|/Users)/[A-Za-z0-9._-]+(/|["'\''[:space:]]|$)' -- "$f" || true)

    # github.com/<owner>/... with a real-looking owner. Uppercase templates
    # (OWNER, REPOSITORY, ...) and the documented placeholder own-er pass.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      owner=$(printf '%s' "$hit" | sed -E 's|.*github\.com/([A-Za-z0-9_.-]+)/.*|\1|')
      case $owner in
        own-er) continue ;;
      esac
      if printf '%s' "$owner" | grep -qE '^[A-Z][A-Z0-9_-]*$'; then
        continue
      fi
      fail "$pkg" hardcoding "$rel:${hit%%:*} hardcodes github.com owner '$owner': $(printf '%s' "${hit#*:}" | cut -c1-90)"
    done < <(grep -noE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' -- "$f" || true)

    # Vendor / model names. 'cursor' is excluded from the case-insensitive set
    # because lowercase "cursor" is pagination vocabulary throughout the
    # packages; the product name is caught case-sensitively as 'Cursor'.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      fail "$pkg" hardcoding "$rel:${hit%%:*} contains a vendor/model name: $(printf '%s' "${hit#*:}" | cut -c1-90)"
    done < <(grep -niE '\b(anthropic|claude|openai|chatgpt|gpt-4|gpt-5|codex|gemini|copilot|mistral|llama)\b' -- "$f" || true)
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      fail "$pkg" hardcoding "$rel:${hit%%:*} contains the vendor name 'Cursor': $(printf '%s' "${hit#*:}" | cut -c1-90)"
    done < <(grep -nE '\bCursor\b' -- "$f" || true)

    # Known-real GitHub logins that were sanitized out.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      fail "$pkg" hardcoding "$rel:${hit%%:*} contains a real GitHub login: $(printf '%s' "${hit#*:}" | cut -c1-90)"
    done < <(grep -niE 'mentaily|tikal' -- "$f" || true)
  done < <(find "$dir" -type f -print0 | sort -z)
}

# Network isolation for the offline test runs.
ISOLATE=()
if unshare -rn true 2>/dev/null; then
  ISOLATE=(unshare -rn)
else
  printf 'note: unshare -rn unavailable; tests run WITHOUT network isolation\n'
fi

check_offline_tests() {
  local pkg=$1 dir=$2 rc=0 log=$scratch/validate.$pkg.log
  if [ ! -f "$dir/tests/validate.sh" ]; then
    fail "$pkg" offline-tests "tests/validate.sh is missing"
    return 0
  fi
  ( cd "$dir" && timeout 180 ${ISOLATE[@]+"${ISOLATE[@]}"} ./tests/validate.sh ) > "$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$pkg" offline-tests "tests/validate.sh exited $rc; last lines: $(tail -3 "$log" | tr '\n' ' | ' | cut -c1-200)"
  fi
}

# ---------------------------------------------------------------- main loop

for arg in "$@"; do
  dir=${arg%/}
  pkg=${dir##*/}
  PKG_ORDER+=("$pkg")
  PKG_FAILS[$pkg]=${PKG_FAILS[$pkg]:-0}
  printf '\n=== %s (%s)\n' "$pkg" "$dir"

  if [ ! -d "$dir" ]; then
    fail "$pkg" package "directory does not exist: $dir"
    continue
  fi
  if [ -z "${MANIFEST[$pkg]:-}" ]; then
    fail "$pkg" package "unknown package '$pkg' (not one of the ten specified packages)"
    continue
  fi

  check_manifest        "$pkg" "$dir" "${MANIFEST[$pkg]}"
  check_frontmatter     "$pkg" "$dir"
  check_scripts         "$pkg" "$dir"
  check_shared_integrity "$pkg" "$dir"
  check_dangling_refs   "$pkg" "$dir"
  check_forbidden       "$pkg" "$dir"
  check_hardcoding      "$pkg" "$dir"
  check_offline_tests   "$pkg" "$dir"
done

# --------------------------------------- cross-package byte-identity check

printf '\n=== cross-package shared-component identity\n'
if [ "${#COMP_RECORDS[@]}" -gt 0 ]; then
  printf '%s\n' "${COMP_RECORDS[@]}" | sort > "$scratch/comps.tsv"
  while IFS= read -r comp; do
    n_hashes=$(awk -F'\t' -v c="$comp" '$1==c {print $2}' "$scratch/comps.tsv" | sort -u | wc -l)
    if [ "$n_hashes" -gt 1 ]; then
      # With a strict majority, the modal hash is treated as canonical and the
      # minority copies fail; with no majority, every copy fails as divergent.
      counts=$(awk -F'\t' -v c="$comp" '$1==c {print $2}' "$scratch/comps.tsv" | sort | uniq -c | sort -rn)
      top=$(printf '%s\n' "$counts" | sed -n '1s/^[[:space:]]*\([0-9]*\).*/\1/p')
      second=$(printf '%s\n' "$counts" | sed -n '2s/^[[:space:]]*\([0-9]*\).*/\1/p')
      if [ "${top:-0}" -gt "${second:-0}" ]; then
        modal=$(printf '%s\n' "$counts" | head -1 | awk '{print $2}')
        while IFS=$'\t' read -r _ hash p; do
          if [ "$hash" != "$modal" ]; then
            fail "$p" shared-identity "$comp differs from the copies in other packages (this copy $hash, majority $modal)"
          fi
        done < <(awk -F'\t' -v c="$comp" '$1==c' "$scratch/comps.tsv")
      else
        while IFS=$'\t' read -r _ hash p; do
          fail "$p" shared-identity "$comp copies diverge across the supplied packages with no majority (this copy $hash)"
        done < <(awk -F'\t' -v c="$comp" '$1==c' "$scratch/comps.tsv")
      fi
    fi
  done < <(cut -f1 "$scratch/comps.tsv" | sort -u)
fi
printf 'checked %s shared-component copies across %s packages\n' "${#COMP_RECORDS[@]}" "${#PKG_ORDER[@]}"

# ------------------------------------------------------------------ summary

printf '\n=== summary\n'
overall=0
for pkg in "${PKG_ORDER[@]}"; do
  if [ "${PKG_FAILS[$pkg]}" -eq 0 ]; then
    printf 'PASS  %-18s (%s informational)\n' "$pkg" "${PKG_INFOS[$pkg]:-0}"
  else
    printf 'FAIL  %-18s %s failure(s), %s informational\n' "$pkg" "${PKG_FAILS[$pkg]}" "${PKG_INFOS[$pkg]:-0}"
    overall=1
  fi
done
printf 'total: %s failure(s), %s informational note(s)\n' "$TOTAL_FAILS" "$TOTAL_INFOS"
exit "$overall"
