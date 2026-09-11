#!/usr/bin/env bash
# Offline validation for this package: the versioned schemas parse and self-check,
# tests/fixtures/cases.json validates against schemas/cases-v1.json, and every case
# runs against a temporary root with mocked CLIs. Nothing here contacts GitHub.
set -euo pipefail

pkg=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
tests=$pkg/tests
prog=${0##*/}

pass=0
fail=0
skipped=0

say() { printf '%s\n' "$*"; }
ok() { pass=$(( pass + 1 )); printf '  ok    %s\n' "$*"; }
bad() { fail=$(( fail + 1 )); printf '  FAIL  %s\n' "$*"; }

command -v jq >/dev/null 2>&1 || { printf '%s: jq is required\n' "$prog" >&2; exit 2; }

# Fixture trees stand in for a user's own state directory, so build them with the
# permissions the scripts require rather than whatever umask the caller happens to have.
umask 022

safe_work=$(mktemp -d "${TMPDIR:-/tmp}/validate.XXXXXX")
trap 'rm -rf -- "$safe_work"' EXIT

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

# --------------------------------------------------------------------- schemas

say "schemas"
if [ -d "$pkg/schemas" ]; then
  for schema in "$pkg"/schemas/*.json; do
    if jq -e . "$schema" >/dev/null 2>&1; then
      ok "$(basename -- "$schema") parses"
    else
      bad "$(basename -- "$schema") is not valid JSON"
    fi
    version=$(jq -r '.properties.schema_version.maximum // .definitions.schema_version.maximum // empty' "$schema")
    if [ -n "$version" ]; then
      ok "$(basename -- "$schema") pins schema_version to $version"
    fi
  done
else
  skipped=$(( skipped + 1 ))
  say "  (this package ships no schemas)"
fi

# ----------------------------------------------------------------- fixtures

cases_file=$tests/fixtures/cases.json
if [ ! -f "$cases_file" ]; then
  say "fixtures"
  say "  (this package ships no case fixtures)"
  printf '\n%s: %s passed, %s failed\n' "$prog" "$pass" "$fail"
  [ "$fail" = 0 ] || exit 1
  exit 0
fi

say "fixtures"
validate_doc "$pkg/schemas/cases-v1.json" "$cases_file" "tests/fixtures/cases.json"

# --------------------------------------------------------------------- cases

now=$(date +%s)
past=$(( now - 100000 ))

subst() {
  # {home} resolves to the case's materialized root as well, so a case can hand a
  # script a fixture path — a lane profile, a poll snapshot — that only exists once
  # the case has been built.
  printf '%s' "$1" \
    | sed -e "s|{{PKG}}|$pkg|g" -e "s|{{TMP}}|$case_root|g" \
          -e "s|{{NOW}}|$now|g" -e "s|{{PAST}}|$past|g" \
          -e "s|{home}|$case_root|g"
}

tree_hash() {
  local dir=$1
  if [ ! -d "$dir" ]; then printf 'absent'; return 0; fi
  {
    find "$dir" \( -type f -o -type d -o -type l \) -printf '%p %y\n' 2>/dev/null
    find "$dir" -type f -exec cksum {} + 2>/dev/null
  } | LC_ALL=C sort | cksum
}

say "cases"
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
  before=$(tree_hash "$case_root/project")
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
  after=$(tree_hash "$case_root/project")

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
     && [ "$before" != "$after" ]; then
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

printf '\n%s: %s passed, %s failed\n' "$prog" "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
exit 0
