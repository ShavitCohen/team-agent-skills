#!/usr/bin/env bash
# Offline validation for this package. It exercises the read-only capacity gate, checks
# the durable comment templates, verifies each shared component against its provenance
# hash, validates the versioned schemas and fixtures, and runs every fixture case against
# a temporary root with mocked CLIs — without contacting GitHub, without mutating any
# environment, and without creating a cluster, a container, or a checkout.
set -euo pipefail

pkg=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
prog=${0##*/}
preflight=$pkg/scripts/k8s_preflight.py

pass=0
fail=0
say() { printf '%s\n' "$*"; }
ok() { pass=$(( pass + 1 )); printf '  ok    %s\n' "$*"; }
bad() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$*"; }

command -v python3 >/dev/null 2>&1 || { printf '%s: python3 is required\n' "$prog" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf '%s: jq is required\n' "$prog" >&2; exit 2; }
command -v sha256sum >/dev/null 2>&1 || { printf '%s: sha256sum is required\n' "$prog" >&2; exit 2; }

# Fixture trees stand in for a user's own state directory, so build them with the
# permissions the scripts require rather than whatever umask the caller happens to have.
umask 022

safe_work=$(mktemp -d "${TMPDIR:-/tmp}/validate.XXXXXX")
trap 'rm -rf -- "$safe_work"' EXIT
mkdir -p "$safe_work/project" "$safe_work/emptybin"
printf 'this file must not change\n' > "$safe_work/project/keep.txt"

tree_hash() {
  {
    find "$1" \( -type f -o -type d -o -type l \) -printf '%p %y\n' 2>/dev/null
    find "$1" -type f -exec cksum {} + 2>/dev/null
  } | LC_ALL=C sort | cksum
}

out=''
rc=0
run() {
  # run EXPECTED_EXIT ARGS... — captures stdout in $out
  local expected=$1; shift
  set +e
  out=$(python3 "$preflight" "$@" 2>"$safe_work/stderr")
  rc=$?
  set -e
  if [ "$rc" = "$expected" ]; then
    return 0
  fi
  printf '        stderr: %s\n' "$(head -n 2 "$safe_work/stderr" | tr '\n' ' ')"
  return 1
}

# ------------------------------------------------------------------ the helper

say "capacity gate"

if [ -x "$preflight" ]; then ok "scripts/k8s_preflight.py is executable"; else bad "scripts/k8s_preflight.py is not executable"; fi
if head -n 1 "$preflight" | grep -q '^#!/usr/bin/env python3$'; then
  ok "scripts/k8s_preflight.py declares a portable interpreter"
else
  bad "scripts/k8s_preflight.py has no portable shebang"
fi
if python3 "$preflight" --help >/dev/null 2>&1; then
  ok "scripts/k8s_preflight.py answers --help"
else
  bad "scripts/k8s_preflight.py does not answer --help"
fi

# A machine with no container runtime is a normal machine, so the zero-runtime form
# must be able to reach `proceed`; anything else would make the helper a Kubernetes
# gate wearing a generic name.
before=$(tree_hash "$safe_work/project")
if run 0 --path "$safe_work/project" --min-cpus 0 --min-total-memory-gib 0 \
        --min-available-memory-gib 0 --min-runtime-cpus 0 --min-runtime-memory-gib 0 \
        --min-disk-gib 0 --max-load-per-cpu 1000; then
  ok "a satisfied gate recommends proceed and exits 0"
else
  bad "a satisfied gate did not exit 0 (got $rc)"
fi
after=$(tree_hash "$safe_work/project")
if [ "$before" = "$after" ]; then ok "the gate mutates nothing on disk"; else bad "the gate changed the project tree"; fi

if printf '%s' "$out" | jq -e '.read_only == true' >/dev/null 2>&1; then
  ok "the report declares itself read-only"
else
  bad "the report does not declare itself read-only"
fi
if printf '%s' "$out" | jq -e '.schema_version | numbers' >/dev/null 2>&1; then
  ok "the report is versioned"
else
  bad "the report carries no schema_version"
fi
if printf '%s' "$out" | jq -e '.kubernetes.current_context_is_local == "unverified"' >/dev/null 2>&1; then
  ok "context locality is reported as unverified, never inferred from a name"
else
  bad "context locality is not reported as unverified"
fi
if printf '%s' "$out" | jq -e '.required_commands | has("kubectl") | not' >/dev/null 2>&1; then
  ok "kubectl is not required unless the caller declares it"
else
  bad "kubectl is required by default"
fi
if printf '%s' "$out" | jq -e '.requirements.kubernetes == false' >/dev/null 2>&1; then
  ok "a run that never names kubectl is not treated as a Kubernetes run"
else
  bad "a non-Kubernetes run was treated as one"
fi

# A threshold no machine can meet must be a blocker, deterministically.
if run 20 --path "$safe_work/project" --min-cpus 100000 --min-runtime-cpus 0 --min-runtime-memory-gib 0; then
  ok "an impossible CPU threshold returns do-not-run"
else
  bad "an impossible CPU threshold did not return do-not-run (got $rc)"
fi
if printf '%s' "$out" | jq -e '.recommendation == "do-not-run" and (.blockers | length) > 0' >/dev/null 2>&1; then
  ok "do-not-run names its blocker"
else
  bad "do-not-run did not name a blocker"
fi

if run 20 --path "$safe_work/project" --min-cpus 0 --min-total-memory-gib 0 \
        --min-available-memory-gib 0 --min-runtime-cpus 0 --min-runtime-memory-gib 0 \
        --min-disk-gib 0 --max-load-per-cpu 1000 \
        --require-command definitely-not-a-real-command-xyz; then
  ok "a missing declared command returns do-not-run"
else
  bad "a missing declared command did not return do-not-run (got $rc)"
fi
if printf '%s' "$out" | jq -e '.required_commands["definitely-not-a-real-command-xyz"] == false' >/dev/null 2>&1; then
  ok "the missing command is reported by name"
else
  bad "the missing command is not reported by name"
fi
if printf '%s' "$out" | jq -e '.requirements.kubernetes == false' >/dev/null 2>&1; then
  ok "declaring an unrelated command does not imply Kubernetes"
else
  bad "declaring an unrelated command implied Kubernetes"
fi

if run 20 --path "$safe_work/project" --min-cpus 0 --min-total-memory-gib 0 \
        --min-available-memory-gib 0 --min-runtime-cpus 0 --min-runtime-memory-gib 0 \
        --min-disk-gib 0 --max-load-per-cpu 1000 \
        --require-command kubectl --require-command definitely-not-a-real-command-xyz; then
  if printf '%s' "$out" | jq -e '.requirements.kubernetes == true' >/dev/null 2>&1; then
    ok "naming kubectl is what makes a run a Kubernetes run"
  else
    bad "naming kubectl did not make it a Kubernetes run"
  fi
else
  bad "the Kubernetes form did not evaluate (got $rc)"
fi

if run 0 --path "$safe_work/project" --min-cpus 0 --min-total-memory-gib 0 \
        --min-available-memory-gib 0 --min-runtime-cpus 0 --min-runtime-memory-gib 0 \
        --min-disk-gib 0 --max-load-per-cpu 1000 --format text; then
  if printf '%s' "$out" | grep -q '^recommendation: '; then
    ok "text format leads with the recommendation"
  else
    bad "text format does not lead with the recommendation"
  fi
else
  bad "text format did not run (got $rc)"
fi

# The helper must not need anything but the interpreter: with no other CLI on PATH it
# still measures what it can and reports the rest as unobservable.
python3_bin=$(command -v python3)
set +e
PATH="$safe_work/emptybin" "$python3_bin" "$preflight" --path "$safe_work/project" \
  --min-runtime-cpus 0 --min-runtime-memory-gib 0 >"$safe_work/nopath" 2>&1
nopath_rc=$?
set -e
if [ "$nopath_rc" = 0 ] || [ "$nopath_rc" = 10 ] || [ "$nopath_rc" = 20 ]; then
  ok "the gate still reports with no other CLI on PATH"
else
  bad "the gate failed with an empty PATH (got $nopath_rc)"
fi

# ------------------------------------------------------------- comment templates

say "comment templates"
templates=$pkg/references/comment-format.md
for needle in \
  '<!-- manual-qa:test-plan -->' \
  '<!-- manual-qa:test-results -->' \
  'From Manual QA Agent' \
  'Manual QA status' \
  'PASS' 'FAIL' 'BLOCKED' 'STALE' \
  'merge base' \
  'Cleanup'
do
  if grep -qF -- "$needle" "$templates"; then
    ok "comment-format.md carries $needle"
  else
    bad "comment-format.md is missing $needle"
  fi
done

# The plan is a promise made before the product is observed, so its template must ask
# for the expectation, not only the result.
if grep -qiE 'expected' "$templates"; then
  ok "the plan template asks for an expected result per scenario"
else
  bad "the plan template does not ask for an expected result"
fi

# ------------------------------------------------------------------- boundaries

say "boundaries"
skill=$pkg/SKILL.md
# The shipped content only — this file names the forbidden invocations in order to
# look for them, and would otherwise match itself.
for forbidden in 'gh pr merge' 'gh pr review --approve' 'gh issue edit' 'git push'; do
  # Manual QA itself never pushes. The shared identity components document the guarded
  # push that sibling skills use, so the push check covers only the content this
  # package authors.
  case $forbidden in
    'git push') scope=("$skill" "$pkg/references/comment-format.md" "$pkg/scripts/k8s_preflight.py") ;;
    *)          scope=("$skill" "$pkg/references" "$pkg/scripts") ;;
  esac
  if grep -rqF -- "$forbidden" "${scope[@]}"; then
    bad "the package contains a forbidden invocation: $forbidden"
  else
    ok "the shipped content contains no $forbidden"
  fi
done
if grep -qF 'never claim `PASS` for a skipped, blocked, stale, or partially executed plan' "$skill"; then
  ok "SKILL.md forbids claiming PASS for an incomplete plan"
else
  bad "SKILL.md does not forbid claiming PASS for an incomplete plan"
fi

# ------------------------------------------------- shared-component provenance

say "shared components"

component_body_hash() {
  # component_body_hash FILE — the file with its provenance header line removed:
  # line 1 for Markdown, line 2 for scripts and schemas.
  case $1 in
    *.md) sed '1d' "$1" | sha256sum | cut -d' ' -f1 ;;
    *)    sed '2d' "$1" | sha256sum | cut -d' ' -f1 ;;
  esac
}

component_header() {
  case $1 in
    *.md) sed -n '1p' "$1" ;;
    *)    sed -n '2p' "$1" ;;
  esac
}

for component in \
  references/policy/identity.md \
  references/policy/trust.md \
  schemas/cases-v1.json \
  schemas/shared-state-v1.json \
  scripts/gh_identity.sh \
  scripts/run_lock.sh
do
  f=$pkg/$component
  if [ ! -f "$f" ]; then
    bad "shared component is missing: $component"
    continue
  fi
  header=$(component_header "$f")
  case $header in
    *shared-component:*) : ;;
    *) bad "no provenance header: $component"; continue ;;
  esac
  want=$(printf '%s' "$header" | grep -oE 'sha256=[0-9a-f]{64}' | cut -d= -f2 || true)
  if [ -z "$want" ]; then
    bad "provenance header names no sha256: $component"
  elif [ "$want" = "$(component_body_hash "$f")" ]; then
    ok "$component matches its provenance hash"
  else
    bad "shared component has drifted from its provenance hash: $component"
  fi
done

# --------------------------------------------------------------------- schemas

say "schemas"
for schema in "$pkg"/schemas/*.json; do
  if [ ! -e "$schema" ]; then
    bad "schemas/ ships no JSON schema"
    continue
  fi
  if jq -e . "$schema" >/dev/null 2>&1; then
    ok "$(basename -- "$schema") parses"
  else
    bad "$(basename -- "$schema") is not valid JSON"
  fi
  version=$(jq -r '.properties.schema_version.maximum // .definitions.schema_version.maximum // empty' "$schema" 2>/dev/null || true)
  if [ -n "$version" ]; then
    ok "$(basename -- "$schema") pins schema_version to $version"
  fi
done

# --------------------------------------------------------------------------
# A compact JSON Schema subset validator: type, required, properties,
# additionalProperties, enum, const, pattern, minimum, maximum, items,
# minItems, oneOf, and local $ref into #/definitions.
# --------------------------------------------------------------------------
cat > "$safe_work/validator.jq" <<'JQ'
def deref($s; $root):
  if ($s | type) == "object" and ($s | has("$ref"))
  then ($root | getpath($s["$ref"] | ltrimstr("#/") | split("/")))
  else $s end;

def typeok($t; $d):
  (if ($t | type) == "array" then $t else [$t] end) as $ts
  | ($d | type) as $dt
  | any($ts[];
      . == $dt
      or (. == "integer" and $dt == "number" and ($d | floor) == $d)
      or (. == "number" and $dt == "number"));

def check($s0; $d; $root; $p):
  deref($s0; $root) as $s
  | if ($s | type) != "object" then []
    else
      [
        (if ($s | has("type")) and (typeok($s.type; $d) | not)
         then "\($p): expected type \($s.type), got \($d | type)" else empty end),
        (if ($s | has("enum")) and ([$s.enum[] | . == $d] | any | not)
         then "\($p): value is not one of the allowed values" else empty end),
        (if ($s | has("const")) and ($s.const != $d)
         then "\($p): value is not the required constant \($s.const)" else empty end),
        (if ($s | has("pattern")) and (($d | type) == "string") and (($d | test($s.pattern)) | not)
         then "\($p): does not match pattern \($s.pattern)" else empty end),
        (if ($s | has("minimum")) and (($d | type) == "number") and ($d < $s.minimum)
         then "\($p): below minimum \($s.minimum)" else empty end),
        (if ($s | has("maximum")) and (($d | type) == "number") and ($d > $s.maximum)
         then "\($p): above maximum \($s.maximum)" else empty end),
        (if ($s | has("minItems")) and (($d | type) == "array") and (($d | length) < $s.minItems)
         then "\($p): fewer than \($s.minItems) items" else empty end),
        (if ($s | has("required")) and (($d | type) == "object")
         then ($s.required[] as $r | select(($d | has($r)) | not)
               | "\($p): missing required property \($r)")
         else empty end),
        (if ($s.additionalProperties == false) and (($d | type) == "object")
         then ($d | keys_unsorted[] as $k | select((($s.properties // {}) | has($k)) | not)
               | "\($p): unexpected property \($k)")
         else empty end),
        (if ($s | has("properties")) and (($d | type) == "object")
         then ($s.properties | keys_unsorted[]) as $k
              | if ($d | has($k)) then check($s.properties[$k]; $d[$k]; $root; "\($p).\($k)")[] else empty end
         else empty end),
        (if (($s.additionalProperties | type) == "object") and (($d | type) == "object")
         then ($d | keys_unsorted[]) as $k
              | if ((($s.properties // {}) | has($k)) | not)
                then check($s.additionalProperties; $d[$k]; $root; "\($p).\($k)")[] else empty end
         else empty end),
        (if ($s | has("items")) and (($d | type) == "array")
         then range(0; $d | length) as $i | check($s.items; $d[$i]; $root; "\($p)[\($i)]")[]
         else empty end),
        (if ($s | has("oneOf"))
         then (if ([$s.oneOf[] | check(.; $d; $root; $p) | select(length == 0)] | length) == 1
               then empty else "\($p): matches no alternative of oneOf" end)
         else empty end)
      ]
    end;

def validate($schema; $data): check($schema; $data; $schema; "$");
JQ

validate_doc() {
  # validate_doc SCHEMA_FILE DATA_FILE LABEL
  local schema=$1 data=$2 label=$3 errors
  errors=$(jq -n -L "$safe_work" --slurpfile s "$schema" --slurpfile d "$data" \
    'include "validator"; validate($s[0]; $d[0]) | .[]' 2>&1 || printf 'validator error')
  if [ -z "$errors" ]; then
    ok "$label validates against $(basename -- "$schema")"
  else
    bad "$label: $(printf '%s' "$errors" | head -n 5 | tr '\n' ' ')"
  fi
}

# -------------------------------------------------------------------- fixtures

say "fixtures"
cases_file=$pkg/tests/fixtures/cases.json
cases_schema=$pkg/schemas/cases-v1.json
if [ ! -f "$cases_file" ]; then
  bad "tests/fixtures/cases.json is missing"
elif [ ! -f "$cases_schema" ]; then
  bad "schemas/cases-v1.json is missing, so the fixtures cannot be validated"
else
  validate_doc "$cases_schema" "$cases_file" "tests/fixtures/cases.json"
fi

# ----------------------------------------------------------------------- cases

say "cases"
if [ ! -f "$cases_file" ]; then
  say "  (skipped: this package ships no case fixtures)"
else

now=$(date +%s)
past=$(( now - 100000 ))

subst() {
  printf '%s' "$1" \
    | sed -e "s|{{PKG}}|$pkg|g" -e "s|{{TMP}}|$case_root|g" \
          -e "s|{{NOW}}|$now|g" -e "s|{{PAST}}|$past|g"
}

case_tree_hash() {
  local dir=$1
  if [ ! -d "$dir" ]; then printf 'absent'; return 0; fi
  {
    find "$dir" \( -type f -o -type d -o -type l \) -printf '%p %y\n' 2>/dev/null
    find "$dir" -type f -exec cksum {} + 2>/dev/null
  } | LC_ALL=C sort | cksum
}

total=$(jq -r '.cases | length' "$cases_file")
index=0
while [ "$index" -lt "$total" ]; do
  case_json=$(jq -c ".cases[$index]" "$cases_file")
  index=$(( index + 1 ))
  id=$(printf '%s' "$case_json" | jq -r '.id')
  case_root=$safe_work/$id
  mkdir -p "$case_root/bin"

  # filesystem
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    mkdir -p "$(subst "$d")"
  done <<EOF
$(printf '%s' "$case_json" | jq -r '.given.fs.dirs[]? // empty')
EOF
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    target=$(subst "$f")
    mkdir -p "$(dirname -- "$target")"
    subst "$(printf '%s' "$case_json" | jq -r --arg k "$f" '.given.fs.files[$k]')" > "$target"
  done <<EOF
$(printf '%s' "$case_json" | jq -r '.given.fs.files // {} | keys_unsorted[]')
EOF
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    link=$(subst "$l")
    dest=$(subst "$(printf '%s' "$case_json" | jq -r --arg k "$l" '.given.fs.symlinks[$k]')")
    mkdir -p "$(dirname -- "$link")"
    ln -sfn "$dest" "$link"
  done <<EOF
$(printf '%s' "$case_json" | jq -r '.given.fs.symlinks // {} | keys_unsorted[]')
EOF
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    chmod "$(printf '%s' "$case_json" | jq -r --arg k "$m" '.given.fs.modes[$k]')" "$(subst "$m")"
  done <<EOF
$(printf '%s' "$case_json" | jq -r '.given.fs.modes // {} | keys_unsorted[]')
EOF

  # mocked gh
  printf '%s' "$case_json" | jq -c '.given.gh // {}' > "$case_root/gh-mock.json"
  cat > "$case_root/bin/gh" <<'MOCK'
#!/usr/bin/env bash
joined="$*"
best=''
best_len=0
while IFS= read -r key; do
  [ -n "$key" ] || continue
  case $joined in
    *"$key"*)
      if [ "${#key}" -gt "$best_len" ]; then best=$key; best_len=${#key}; fi
      ;;
  esac
done < <(jq -r 'keys_unsorted[]' "$MOCK_GH")
if [ -z "$best" ]; then
  printf 'mock gh: no fixture for: %s\n' "$joined" >&2
  exit 1
fi
last=${*: -1}
value=$(jq -r --arg k "$best" '.[$k]' "$MOCK_GH")
value=${value//\$MOCK_LAST_ARG/$last}
value=${value//\$GH_TOKEN_SUFFIX/${GH_TOKEN#token-}}
value=${value//\$GH_TOKEN/${GH_TOKEN:-}}
case $value in
  '!'*) printf '%s\n' "${value#!}" >&2; exit 1 ;;
esac
printf '%s\n' "$value"
MOCK
  chmod 755 "$case_root/bin/gh"

  # environment
  env_args=()
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    env_args+=("$key=$(subst "$(printf '%s' "$case_json" | jq -r --arg k "$key" '.given.env[$k]')")")
  done <<EOF
$(printf '%s' "$case_json" | jq -r '.given.env // {} | keys_unsorted[]')
EOF

  argv=()
  while IFS= read -r a; do
    argv+=("$(subst "$a")")
  done <<EOF
$(printf '%s' "$case_json" | jq -r '.invoke[]')
EOF

  mkdir -p "$case_root/home"
  case_before=$(case_tree_hash "$case_root/project")
  set +e
  stdout=$(env \
    PATH="$case_root/bin:$PATH" \
    MOCK_GH="$case_root/gh-mock.json" \
    HOME="$case_root/home" \
    ${env_args[@]+"${env_args[@]}"} \
    "${argv[@]}" 2>"$case_root/stderr")
  rc=$?
  set -e
  stderr=$(cat "$case_root/stderr")
  case_after=$(case_tree_hash "$case_root/project")

  problems=''
  expected_rc=$(printf '%s' "$case_json" | jq -r '.expect.exit_code // empty')
  if [ -n "$expected_rc" ] && [ "$rc" != "$expected_rc" ]; then
    problems="$problems exit=$rc(want $expected_rc)"
  fi
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if ! printf '%s' "$stdout" | grep -qE -- "$(subst "$pattern")"; then
      problems="$problems stdout!~/$pattern/"
    fi
  done <<EOF
$(printf '%s' "$case_json" | jq -r '.expect.stdout_matches[]? // empty')
EOF
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if printf '%s' "$stdout" | grep -qE -- "$(subst "$pattern")"; then
      problems="$problems stdout~/$pattern/"
    fi
  done <<EOF
$(printf '%s' "$case_json" | jq -r '.expect.stdout_not_matches[]? // empty')
EOF
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    if ! printf '%s' "$stderr" | grep -qE -- "$(subst "$pattern")"; then
      problems="$problems stderr!~/$pattern/"
    fi
  done <<EOF
$(printf '%s' "$case_json" | jq -r '.expect.stderr_matches[]? // empty')
EOF
  if [ "$(printf '%s' "$case_json" | jq -r '.expect.fs_unchanged // false')" = true ] \
     && [ "$case_before" != "$case_after" ]; then
    problems="$problems project-tree-changed"
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -e "$(subst "$p")" ]; then problems="$problems missing:$p"; fi
  done <<EOF
$(printf '%s' "$case_json" | jq -r '.expect.path_exists[]? // empty')
EOF
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$(subst "$p")" ]; then problems="$problems present:$p"; fi
  done <<EOF
$(printf '%s' "$case_json" | jq -r '.expect.path_absent[]? // empty')
EOF

  if [ -z "$problems" ]; then
    ok "$id"
  else
    bad "$id —$problems"
    printf '        stderr: %s\n' "$(printf '%s' "$stderr" | head -n 3 | tr '\n' ' ')"
  fi
done

fi

printf '\n%s: %s passed, %s failed\n' "$prog" "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
exit 0
