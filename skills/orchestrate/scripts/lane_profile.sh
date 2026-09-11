#!/usr/bin/env bash
# Resolve and validate the orchestration lane profile.
#
# It answers one question — which lane, model, and reasoning tier does each stage run
# on for THIS runtime — and it answers it the same way every time. It reads a profile,
# never writes one; it reports whether a lane's executable exists, never runs it; and
# it contacts nothing. A profile it cannot understand is refused rather than guessed
# past, because a misread lane silently sends the Reviewer back to the runtime that
# wrote the code.
set -euo pipefail

prog=${0##*/}
SCHEMA_VERSION=1
STAGES="create-clarity implement pr-review pr-fix manual-qa"

die() { printf '%s: %s\n' "$prog" "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

usage() {
  cat <<'EOF'
lane_profile.sh resolve --runtime LABEL [--profile PATH] [--stage STAGE] [--cwd DIR] [--check-commands] [--decision-policy attended|yolo]
lane_profile.sh validate [--profile PATH]
lane_profile.sh example

resolve emits versioned JSON: the source (profile or default), the matched runtime
key, and each stage's lane, model, tier, and resolved cli entry. With --check-commands
it also reports whether each cli executable exists, without running it.

It also resolves the run's decision policy — who answers when a stage would need the
human — with its own source: --decision-policy is the request's word and wins, else
the profile's top-level decision_policy, else attended. The profile's yolo block, the
one value a yolo run cannot derive for itself, is passed through when present.

The built-in default names no runtime, model, or vendor: the interactive stages run
inline and the rest as sub-agents of this runtime, with inherited models.

A profile chooses lanes and models only. How a monitoring stage is invoked is not
its business: under orchestration no stage attaches a watcher of its own, and each
is invoked one wake-up pass at a time, so an "invocation" key is refused rather
than ignored.

Command templates substitute {model}, {effort}, and {cwd}. An unfilled {model} or
{effort} is dropped together with the flag immediately before it, so a template
written for a runtime that takes --model does not hand it an empty argument.

validate refuses a newer schema_version, an unknown stage, an unknown lane, a lane
that names an undefined cli entry, a command that is not a non-empty array of
strings, an invocation key on any stage, and a decision_policy that is neither
attended nor yolo. example prints the placeholder profile from references/lanes.md.
EOF
}

state_root() {
  # The same private layout run_lock.sh owns; the profile is a user file inside it.
  if [ -n "${TEAM_SKILLS_STATE_DIR:-}" ]; then
    printf '%s' "$TEAM_SKILLS_STATE_DIR"
  elif [ -n "${XDG_STATE_HOME:-}" ]; then
    printf '%s/team-agent-skills' "$XDG_STATE_HOME"
  else
    printf '%s/.local/state/team-agent-skills' "$HOME"
  fi
}

default_profile_path() { printf '%s/config/orchestrate.json' "$(state_root)"; }

example_profile() {
  cat <<'EOF'
{
  "schema_version": 1,
  "decision_policy": "attended",
  "yolo": {
    "human_reviewer": null
  },
  "runtimes": {
    "RUNTIME-KEY": {
      "match": ["<case-insensitive substring of the label that runtime exposes>"],
      "stages": {
        "create-clarity":   { "lane": "inline", "model": null, "effort": null },
        "implement":        { "lane": "inline", "model": null, "effort": null },
        "pr-review":        { "lane": "cli:OTHER-RUNTIME", "model": null, "effort": null },
        "pr-fix":           { "lane": "agent", "model": null, "effort": null },
        "manual-qa":        { "lane": "agent", "model": null, "effort": null }
      }
    },
    "default": { "stages": {} }
  },
  "cli": {
    "OTHER-RUNTIME": {
      "command": ["<executable>", "<arg>", "{model}", "{effort}", "{cwd}"],
      "runtime_label": "<label that runtime exposes, used to recognize its PR messages>",
      "github_login": null,
      "skills_roots": ["<absolute directory holding readable copies of the packages; may be shared>"]
    }
  }
}
EOF
}

# The lane every stage falls back to when no profile says otherwise. It names no
# runtime and no model: the interactive stages stay where the user is, and the rest
# become sub-agents of whatever runtime is running this. No stage carries a mode for
# how it is invoked, because there is only one — the orchestrator holds the single
# poller and invokes each monitoring stage one wake-up pass at a time.
default_plan() {
  jq -nc --arg stages "$STAGES" '
    ($stages | split(" ")) as $names
    | reduce $names[] as $s ({};
        .[$s] = {
            lane: (if $s == "create-clarity" or $s == "implement" then "inline" else "agent" end),
            model: null, effort: null, cli: null
          })'
}

validate_profile() {
  # validate_profile FILE -> prints nothing, exits non-zero with a reason
  local file=$1 problems
  jq -e . "$file" >/dev/null 2>&1 || die "profile is not valid JSON: $file"

  local version
  version=$(jq -r '.schema_version // empty' "$file")
  [ -n "$version" ] || die "profile has no schema_version"
  case $version in
    ''|*[!0-9]*) die "profile schema_version is not a number: $version" ;;
  esac
  [ "$version" -le "$SCHEMA_VERSION" ] \
    || die "profile schema_version $version is newer than this script understands ($SCHEMA_VERSION)"

  problems=$(jq -r --arg stages "$STAGES" '
    ($stages | split(" ")) as $known
    | [ (select(has("decision_policy"))
          | select((.decision_policy | IN("attended", "yolo")) | not)
          | "decision_policy \(.decision_policy | tojson) is neither \"attended\" nor \"yolo\"" ),
        (select(has("yolo")) | select((.yolo | type) != "object")
          | "yolo must be an object naming the one value a yolo run cannot derive, human_reviewer" ),
        (.runtimes // {} | to_entries[]
          | .key as $rt
          | (.value.stages // {} | to_entries[])
          | select((.key | IN($known[])) | not)
          | "unknown stage \"\(.key)\" under runtime \"\($rt)\"" ),
        (.runtimes // {} | to_entries[]
          | .key as $rt
          | (.value.stages // {} | to_entries[])
          | select((.value.lane // "") | test("^(inline|agent|cli:[A-Za-z0-9._-]+)$") | not)
          | "unknown lane \"\(.value.lane // "")\" for stage \"\(.key)\" under runtime \"\($rt)\"" ),
        (.runtimes // {} | to_entries[]
          | .key as $rt
          | (.value.stages // {} | to_entries[])
          | select(.value | type == "object" and has("invocation"))
          | "stage \"\(.key)\" under runtime \"\($rt)\" takes no invocation mode: orchestration invokes every monitoring stage one pass at a time" ),
        (.runtimes // {} | to_entries[]
          | .key as $rt
          | (.value.stages // {} | to_entries[])
          | select((.value.lane // "") | startswith("cli:"))
          | ((.value.lane | sub("^cli:"; ""))) as $name
          | select((($ARGS.named.cli // {}) | has($name)) | not)
          | "stage \"\(.key)\" under runtime \"\($rt)\" names undefined cli entry \"\($name)\"" ),
        (.cli // {} | to_entries[]
          | select((.value.command | type) != "array"
                   or (.value.command | length) == 0
                   or ([.value.command[] | type] | any(. != "string")))
          | "cli entry \"\(.key)\" has no usable command array" )
      ] | .[]' --argjson cli "$(jq -c '.cli // {}' "$file")" "$file")

  if [ -n "$problems" ]; then
    printf '%s: %s\n' "$prog" "$(printf '%s' "$problems" | head -n 1)" >&2
    exit 2
  fi
}

cmd_validate() {
  local file=${1:-$(default_profile_path)}
  [ -f "$file" ] || die "no profile at $file"
  validate_profile "$file"
  printf 'ok: %s validates against schema_version %s\n' "$file" "$SCHEMA_VERSION"
}

cmd_resolve() {
  local runtime='' file='' stage='' cwd='' check=0 requested_policy=''
  while [ $# -gt 0 ]; do
    case $1 in
      --runtime) runtime=${2:?--runtime needs a value}; shift 2 ;;
      --profile) file=${2:?--profile needs a value}; shift 2 ;;
      --stage) stage=${2:?--stage needs a value}; shift 2 ;;
      --cwd) cwd=${2:?--cwd needs a value}; shift 2 ;;
      --check-commands) check=1; shift ;;
      --decision-policy) requested_policy=${2:?--decision-policy needs a value}; shift 2 ;;
      *) die "unexpected option: $1" ;;
    esac
  done
  [ -n "$runtime" ] || die "--runtime is required: pass the label this runtime exposes about itself"
  case $requested_policy in
    ''|attended|yolo) : ;;
    *) die "unknown decision policy: $requested_policy (expected attended or yolo)" ;;
  esac
  if [ -n "$stage" ]; then
    case " $STAGES " in
      *" $stage "*) : ;;
      *) die "unknown stage: $stage" ;;
    esac
  fi
  [ -n "$file" ] || file=$(default_profile_path)

  # The decision policy is the run's, not a lane's: the request's word wins over the
  # profile's, and with neither the run is attended. Its source travels with it, so a
  # reader of the plan can see whether the human chose it or it was assumed.
  local policy='attended' policy_source=default yolo=null
  local plan source matched='' cli='{}'
  if [ -f "$file" ]; then
    validate_profile "$file"
    source=profile
    cli=$(jq -c '.cli // {}' "$file")
    local profile_policy
    profile_policy=$(jq -r '.decision_policy // empty' "$file")
    if [ -n "$profile_policy" ]; then policy=$profile_policy; policy_source=profile; fi
    yolo=$(jq -c '.yolo // null' "$file")
    # Longest match wins, so a specific label is never shadowed by a broader one.
    matched=$(jq -r --arg label "$runtime" '
      (.runtimes // {}) | to_entries
      | map(select(.key != "default"))
      | map(. as $e | ($e.value.match // [])
            | map(. as $m | select(($label | ascii_downcase) | contains($m | ascii_downcase)) | length)
            | max // -1 | {key: $e.key, score: .})
      | map(select(.score >= 0))
      | sort_by(-.score) | (.[0].key // "")' "$file")
    if [ -z "$matched" ] && [ "$(jq -r '.runtimes | has("default")' "$file")" = true ]; then
      matched=default
    fi
    if [ -n "$matched" ]; then
      plan=$(jq -c --arg rt "$matched" --argjson default "$(default_plan)" --arg stages "$STAGES" '
        ($stages | split(" ")) as $names
        | (.runtimes[$rt].stages // {}) as $stages_cfg
        | reduce $names[] as $s ($default;
            .[$s] = (.[$s] + ($stages_cfg[$s] // {} | {lane, model, effort}
                                | with_entries(select(.value != null)))
                     | .model //= null | .effort //= null
                     | .cli = (if (.lane | startswith("cli:")) then (.lane | sub("^cli:"; "")) else null end)))' "$file")
    else
      plan=$(default_plan)
      source=default
    fi
  else
    plan=$(default_plan)
    source=default
  fi
  if [ -n "$requested_policy" ]; then policy=$requested_policy; policy_source=request; fi

  # Substitute the template placeholders, dropping an unfilled {model} or {effort}
  # together with the flag that introduces it: a runtime asked for "--model" with no
  # value would refuse to start, and guessing a model is not this script's business.
  local resolved
  resolved=$(jq -nc \
    --argjson plan "$plan" --argjson cli "$cli" \
    --arg cwd "$cwd" --argjson check "$check" '
    def render($command; $model; $effort; $cwd):
      reduce range(0; $command | length) as $i ([];
        $command[$i] as $arg
        | if $arg == "{model}" then (if $model == null then (.[0:-1]) else . + [$model] end)
          elif $arg == "{effort}" then (if $effort == null then (.[0:-1]) else . + [$effort] end)
          elif $arg == "{cwd}" then (if $cwd == "" then (.[0:-1]) else . + [$cwd] end)
          else . + [$arg] end);
    $plan | with_entries(
      .value as $s
      | .value = ($s + {
          cli_entry: (if $s.cli == null then null
                      else ($cli[$s.cli] // null) end),
          command: (if $s.cli == null or ($cli[$s.cli] // null) == null then null
                    else render($cli[$s.cli].command; $s.model; $s.effort; $cwd) end)
        }))')

  if [ "$check" = 1 ]; then
    local names name present out='{}'
    names=$(printf '%s' "$resolved" | jq -r '[.[] | .command[0]? // empty] | unique[]')
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      if command -v -- "$name" >/dev/null 2>&1; then present=true; else present=false; fi
      out=$(printf '%s' "$out" | jq -c --arg n "$name" --argjson p "$present" '.[$n] = $p')
    done <<EOF
$names
EOF
    resolved=$(jq -nc --argjson r "$resolved" --argjson avail "$out" '
      $r | with_entries(.value.executable_present =
        (if .value.command == null then null else ($avail[.value.command[0]] // false) end))')
  fi

  local plan_out
  if [ -n "$stage" ]; then
    plan_out=$(printf '%s' "$resolved" | jq -c --arg s "$stage" '{($s): .[$s]}')
  else
    plan_out=$resolved
  fi

  jq -nc --argjson schema_version "$SCHEMA_VERSION" \
    --arg source "$source" --arg matched "$matched" --arg runtime "$runtime" \
    --arg profile "$file" --argjson checked "$check" --argjson stages "$plan_out" \
    --arg policy "$policy" --arg policy_source "$policy_source" --argjson yolo "$yolo" \
    '{schema_version:$schema_version, source:$source,
      runtime_label:$runtime,
      matched_runtime:(if $matched == "" then null else $matched end),
      profile_path:(if $source == "profile" then $profile else null end),
      commands_checked:($checked == 1),
      decision_policy:$policy,
      decision_policy_source:$policy_source,
      yolo:$yolo,
      stages:$stages}'
}

main() {
  need jq
  local action=${1:-}
  [ -n "$action" ] || { usage >&2; exit 2; }
  shift || true
  case $action in
    resolve) cmd_resolve "$@" ;;
    validate)
      local file=''
      while [ $# -gt 0 ]; do
        case $1 in
          --profile) file=${2:?--profile needs a value}; shift 2 ;;
          *) die "unexpected option: $1" ;;
        esac
      done
      cmd_validate "$file"
      ;;
    example) example_profile ;;
    -h | --help) usage ;;
    *) die "unknown action: $action" ;;
  esac
}

main "$@"
