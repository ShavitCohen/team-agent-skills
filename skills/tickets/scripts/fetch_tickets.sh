#!/usr/bin/env bash
# Resolve "what is on my plate" into one sorted, link-bearing JSON document.
#
# Two searches, because the two questions have two different authorities:
#
#   * my open pull requests  — asked of the pull requests themselves, which carry
#     their own draft/review/check/merge state. Nothing here is inferred.
#   * my open tickets        — asked of the issue search, and joined to pull
#     requests only through evidence GitHub records: a closing link, or a branch
#     or title that names the ticket by number.
#
# A cross-reference is never evidence. One pull request routinely mentions many
# tickets, and treating a mention as ownership is what put merged work onto
# tickets that had no pull request at all.
#
# Every offline stage is a separate subcommand so parsing, query construction and
# row shaping stay deterministic and testable without a network or a token.
set -euo pipefail

prog=${0##*/}
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SCHEMA_VERSION=2
DEFAULT_CAP=200
workdir=''

die() { printf '%s: %s\n' "$prog" "$*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

usage() {
  cat <<'EOF'
fetch_tickets.sh parse [FREE_TEXT...]        free text -> filter JSON            (offline)
fetch_tickets.sh query [--login LOGIN] < filter.json
                                             filter JSON -> issue search query   (offline)
fetch_tickets.sh pr-query [--login LOGIN] < filter.json
                                             filter JSON -> pull request query   (offline)
fetch_tickets.sh shape < raw-issues.json     raw issue nodes -> sorted rows JSON (offline)
fetch_tickets.sh shape-prs < raw-prs.json    raw PR nodes -> next-move rows JSON (offline)
fetch_tickets.sh whoami                      the login whose work is listed
fetch_tickets.sh board-probe                 whether the project board is readable
fetch_tickets.sh fetch [--login LOGIN] [--cap N] [FREE_TEXT...]
                                             the whole pipeline -> result JSON

Free text is optional and additive: "of s4", "only closed tickets of s4",
"p0 p1", "in OWNER/REPOSITORY", "epics", "no epics", "@LOGIN", "all".
Anything unrecognized becomes a title/body search term and is echoed back
under .filter.unparsed so a misread is visible rather than silent.
EOF
}

# --------------------------------------------------------------------- parse
#
# Free text is matched token by token against a closed vocabulary. A token that
# matches nothing is never dropped: it lands in .text and is reported.

cmd_parse() {
  need jq
  local raw="$*" tok low norm
  local state='' epics='include' login=''
  local sprints=() priorities=() repos=() labels=() text=() unparsed=()

  # Phrase-level normalization first, so multi-word forms collapse to one token
  # and never leave an orphan word behind in the free-text remainder.
  norm=$(printf '%s' "$raw" | sed -E '
    s/,/ /g
    s/[Nn]o(t)?[ -]+(epics?|parents?)/noepics/g
    s/[Ww]ithout[ -]+(epics?|parents?)/noepics/g
    s/[Ss]print[ -]+([0-9]+)/S\1/g
    s/\b(only|of|my|show|list|the|please|in|for|me)\b//g
    s/\b[Tt]ickets?\b//g
    s/\b[Ii]ssues?\b//g')

  for tok in $norm; do
    low=$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]')
    case $low in
      '') ;;
      open|opened|active)           state='open' ;;
      closed|done|finished)         state='closed' ;;
      all|any|everything)           state='all' ;;
      s[0-9]|s[0-9][0-9])           sprints+=("sprint-${low#s}") ;;
      sprint-[0-9]*)                sprints+=("$low") ;;
      p0|urgent|critical)           priorities+=('P0-urgent') ;;
      p1|high)                      priorities+=('P1-high') ;;
      p2|medium|mid)                priorities+=('P2-medium') ;;
      p3|low)                       priorities+=('P3-low') ;;
      epic|epics|parent|parents)    epics='only' ;;
      noepics|leaf|leaves)          epics='exclude' ;;
      blocked)                      labels+=('__blocked__') ;;
      @*)                           login=${tok#@} ;;
      assignee:*)                   login=${tok#*:} ;;
      repo:*)                       repos+=("${tok#*:}") ;;
      */*)                          repos+=("$tok") ;;
      label:*)                      labels+=("${tok#*:}") ;;
      *)                            text+=("$tok"); unparsed+=("$tok") ;;
    esac
  done

  [ -n "$state" ] || state='open'

  jq -n \
    --arg schema "$SCHEMA_VERSION" \
    --arg state "$state" \
    --arg epics "$epics" \
    --arg login "$login" \
    --arg raw "$raw" \
    --arg text "${text[*]-}" \
    --argjson sprints "$(printf '%s\n' ${sprints+"${sprints[@]}"} | jq -R . | jq -sc 'map(select(length>0))|unique')" \
    --argjson priorities "$(printf '%s\n' ${priorities+"${priorities[@]}"} | jq -R . | jq -sc 'map(select(length>0))|unique')" \
    --argjson repos "$(printf '%s\n' ${repos+"${repos[@]}"} | jq -R . | jq -sc 'map(select(length>0))|unique')" \
    --argjson labels "$(printf '%s\n' ${labels+"${labels[@]}"} | jq -R . | jq -sc 'map(select(length>0))|unique')" \
    --argjson unparsed "$(printf '%s\n' ${unparsed+"${unparsed[@]}"} | jq -R . | jq -sc 'map(select(length>0))|unique')" \
    '{
       schemaVersion: ($schema|tonumber),
       requested: $raw,
       assignee: (if $login == "" then null else $login end),
       state: $state,
       sprints: $sprints,
       priorities: $priorities,
       repos: $repos,
       labels: ($labels - ["__blocked__"]),
       blockedOnly: ($labels | index("__blocked__") != null),
       epics: $epics,
       text: ($text | gsub("^ +| +$";"")),
       unparsed: $unparsed
     }'
}

# --------------------------------------------------------------------- query
#
# Same-qualifier OR is expressed with commas; different qualifiers AND together.
# No organization is ever assumed: `assignee:` alone already means "mine, everywhere".

cmd_query() {
  need jq
  local login='' filter
  while [ $# -gt 0 ]; do
    case $1 in
      --login) login=${2:?--login needs a value}; shift 2 ;;
      *) die "unknown option for query: $1" ;;
    esac
  done
  filter=$(cat)
  printf '%s' "$filter" | jq -r --arg login "$login" '
    [ "is:issue",
      ("assignee:" + (if $login != "" then $login else (.assignee // "@me") end)),
      (if .state == "open" then "is:open" elif .state == "closed" then "is:closed" else empty end),
      (if (.sprints|length) > 0 then "label:" + (.sprints|join(",")) else empty end),
      (if (.priorities|length) > 0 then "label:" + (.priorities|join(",")) else empty end),
      (if (.labels|length) > 0 then (.labels[] | "label:" + .) else empty end),
      (if (.repos|length) > 0 then (.repos[] | "repo:" + .) else empty end),
      (if (.text // "") != "" then .text else empty end)
    ] | join(" ")'
}

# ------------------------------------------------------------------ pr-query
#
# My open pull requests are their own question, not a projection of the ticket
# filter: a pull request with no ticket is still work I owe, and a sprint label
# lives on tickets, not on pull requests. Only the repository narrowing carries
# over, because that one is about where I am working rather than about which
# tickets matched.

cmd_pr_query() {
  need jq
  local login='' filter
  while [ $# -gt 0 ]; do
    case $1 in
      --login) login=${2:?--login needs a value}; shift 2 ;;
      *) die "unknown option for pr-query: $1" ;;
    esac
  done
  filter=$(cat)
  printf '%s' "$filter" | jq -r --arg login "$login" '
    [ "is:pr", "is:open", "archived:false",
      ("author:" + (if $login != "" then $login else (.assignee // "@me") end)),
      (if (.repos|length) > 0 then (.repos[] | "repo:" + .) else empty end)
    ] | join(" ")'
}

# ------------------------------------------------------------------- shape-prs
#
# A pull request states its own condition, so nothing here is derived from a
# neighbouring artifact. The one judgement call is what "failing" means, and it
# is made from the named checks rather than from the rollup: a rollup reports
# FAILURE when a job was cancelled or skipped, which is not work the author owes.

cmd_shape_prs() {
  need jq
  jq -c '
    def contexts:
      (((.commits.nodes // [])[0].commit.statusCheckRollup.contexts.nodes) // []);
    def checkName: (.name // .context // "check");

    # A check the author has to act on. SKIPPED, CANCELLED and NEUTRAL are none
    # of them: a cancelled run is usually one a newer push superseded.
    def isFailing:
      (((.conclusion // "") | IN("FAILURE","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE"))
       or ((.conclusion == null) and ((.state // "") | IN("FAILURE","ERROR"))));
    def isRunning:
      (((.status // "") | IN("QUEUED","IN_PROGRESS","WAITING","PENDING"))
       or ((.conclusion == null) and ((.state // "") == "PENDING")));

    # The tickets this pull request actually claims. The recorded closing link
    # first; failing that, the branch-name convention <type>/<number>-<slug>,
    # which is deterministic and checkable rather than a guess.
    def branchTicket:
      ((.headRefName // "")
       | capture("^(?:[A-Za-z][A-Za-z0-9]*/)?0*(?<n>[0-9]+)-")
       | (.n | tonumber))? // null;

    map(select(.number != null))
    | unique_by(.url)
    | map(
        . as $p
        | ($p.repository.nameWithOwner) as $repo
        | ([ $p | contexts | .[] | select(isFailing) | checkName ] | unique) as $failing
        | ([ $p | contexts | .[] | select(isRunning) | checkName ] | unique) as $running
        | ([ ($p.reviewThreads.nodes // [])[] | select(.isResolved == false) ] | length) as $threads
        | ([ ($p.closingIssuesReferences.nodes // [])[]
             | { number, url, title, state, repo: .repository.nameWithOwner, via: "closing" } ]) as $closes
        | ($p | branchTicket) as $branchN
        | (if ($closes | length) > 0 then $closes
           elif $branchN != null then
             [ { number: $branchN,
                 url: ("https://github.com/" + $repo + "/issues/" + ($branchN|tostring)),
                 title: null, state: null, repo: $repo, via: "branch" } ]
           else [] end) as $claims
        # What the author owes, strongest obligation first. Several can be true
        # at once; all of them are reported, because a table that shows only the
        # first hides half the round trip.
        | ([ (if $p.mergeable == "CONFLICTING" then "Rebase — conflicts with the base branch" else empty end),
             (if $p.reviewDecision == "CHANGES_REQUESTED" then "Address the requested changes" else empty end),
             (if ($failing | length) > 0
              then "Fix " + $failing[0]
                   + (if ($failing|length) > 1
                      then " +" + (($failing|length) - 1 | tostring) + " more" else "" end)
              else empty end),
             (if $threads > 0
              then "Answer " + ($threads|tostring) + " comment thread"
                   + (if $threads == 1 then "" else "s" end)
              else empty end),
             (if $p.isDraft then "Finish and mark ready for review" else empty end)
           ]) as $needs
        | (if ($needs | length) > 0 then { move: $needs[0], owner: "you", rank: 1 }
           elif ($running | length) > 0
             then { move: ("Wait for " + ($running|length|tostring) + " check"
                           + (if ($running|length) == 1 then "" else "s" end)),
                    owner: "waiting", rank: 2 }
           elif $p.reviewDecision == "APPROVED" and $p.mergeable == "MERGEABLE"
             then { move: "Merge", owner: "merge", rank: 0 }
           elif $p.reviewDecision == "APPROVED"
             then { move: ("Approved — merge state is "
                           + (($p.mergeStateStatus // "unknown") | ascii_downcase)),
                    owner: "you", rank: 1 }
           else { move: "Waiting on review", owner: "waiting", rank: 2 } end) as $next
        | {
            repo: $repo,
            number: $p.number,
            url: $p.url,
            title: $p.title,
            isDraft: $p.isDraft,
            mergeable: $p.mergeable,
            mergeStateStatus: $p.mergeStateStatus,
            reviewDecision: $p.reviewDecision,
            updatedAt: $p.updatedAt,
            branch: $p.headRefName,
            checks: { failing: $failing, running: $running,
                      total: ($p | contexts | length) },
            unresolvedThreads: $threads,
            claims: $claims,
            needs: $needs,
            nextMove: $next.move,
            owner: $next.owner,
            # Every fact the row rests on, so the rendered detail cell never has
            # to be invented and never overstates what was read.
            detail: ([ (if ($failing|length) > 0
                        then (($failing|length)|tostring) + " check"
                             + (if ($failing|length) == 1 then "" else "s" end) + " failing"
                        else empty end),
                       (if ($running|length) > 0
                        then (($running|length)|tostring) + " running" else empty end),
                       (if $threads > 0
                        then ($threads|tostring) + " unresolved thread"
                             + (if $threads == 1 then "" else "s" end)
                        else empty end),
                       (if $p.reviewDecision == null then "no review yet"
                        else ($p.reviewDecision | ascii_downcase | gsub("_"; " ")) end),
                       (if $p.mergeable == "CONFLICTING" then "conflicts" else empty end),
                       (if $p.isDraft then "draft" else empty end)
                     ] | join(", ")),
            sortKeys: { rank: $next.rank }
          })
    | sort_by(.sortKeys.rank, (.updatedAt // ""))
    | group_by(.sortKeys.rank)
    | map(reverse) | add // []'
}

# --------------------------------------------------------------------- shape
#
# Ticket rows. Status is derived from readable signals only, in a fixed
# precedence, and each status carries the URL that proves it so the rendered cell
# links to its own evidence instead of to the ticket every time.
#
# Nothing here reports check state. A ticket's own view of a pull request's
# checks would have to come from the rollup, and the rollup is the field that
# calls a cancelled job a failure. Check truth lives in shape-prs, where the
# named contexts are read.

cmd_shape() {
  need jq
  jq -c '
    def prs:
      ((.closedByPullRequestsReferences.nodes // []) | map(. + { authoritative: true }))
      + [ (.timelineItems.nodes // [])[] | (.source // {}) | . + { authoritative: false } ]
      | map(select(.number != null))
      | unique_by(.url);

    def branchTicket:
      ((.headRefName // "")
       | capture("^(?:[A-Za-z][A-Za-z0-9]*/)?0*(?<n>[0-9]+)-")
       | (.n | tonumber))? // null;

    # How strongly a pull request claims this ticket. Only recorded evidence
    # counts: the closing link GitHub itself keeps, or a branch or title that
    # names this ticket by number. Everything else is a mention, and a mention
    # is not a claim — it never reaches the column.
    def linkStrength($repo; $number):
      if .authoritative then 0
      elif (branchTicket == $number) and (.repository.nameWithOwner == $repo) then 1
      elif ((.title // "")
            | test("(#|[Ii]ssue[ _-]?)0*" + ($number|tostring) + "([^0-9]|$)")) then 2
      else 9 end;

    # Which pull request owns the row: strongest claim first, then the one the
    # column actually asks for — an open pull request over a finished one.
    def prRank($repo; $number):
      [ linkStrength($repo; $number),
        (if .state == "OPEN" and (.isDraft | not) then 0
         elif .state == "OPEN" then 1
         elif .merged then 2
         else 3 end),
        (- .number) ];

    def priorityOf:
      ([ .labels.nodes[]?.name | select(test("^P[0-9]-")) ] | sort | first) // null;

    def sprintOf:
      ([ .labels.nodes[]?.name | select(startswith("sprint-")) ] | sort | last)
      // (.title | capture("^\\[?(?<s>[Ss][0-9]+)") | "sprint-" + (.s[1:]))
      // null;

    def status($pr; $blockers; $isEpic):
      if .state == "CLOSED" then
        (if .stateReason == "NOT_PLANNED"
         then { label: "Closed — not planned", rank: 9, href: .url }
         else { label: "Closed", rank: 9, href: (($pr.url) // .url) } end)
      elif ($blockers | length) > 0 then
        { label: "Blocked", rank: 8, href: ($blockers[0].url) }
      elif $isEpic then
        # An epic tracks its children, not its own branch. Report the children.
        { label: ("Epic " + ((.subIssuesSummary.completed // 0)|tostring) + "/"
                  + ((.subIssuesSummary.total // 0)|tostring) + " done"),
          rank: 7, href: .url }
      elif $pr == null then
        { label: "Not started", rank: 6, href: .url }
      elif $pr.merged then
        { label: "PR merged — ticket open", rank: 1, href: $pr.url }
      elif $pr.state == "CLOSED" then
        { label: "PR closed unmerged", rank: 0, href: $pr.url }
      elif $pr.reviewDecision == "CHANGES_REQUESTED" then
        { label: "Changes requested", rank: 0, href: $pr.url }
      elif $pr.isDraft then
        { label: "Draft PR", rank: 4, href: $pr.url }
      elif $pr.reviewDecision == "APPROVED" then
        { label: "Approved", rank: 2, href: $pr.url }
      else
        { label: "In review", rank: 3, href: $pr.url }
      end;

    def priorityRank:
      { "P0-urgent": 0, "P1-high": 1, "P2-medium": 2, "P3-low": 3 };

    map(select(.number != null))
    | unique_by(.url)
    | map(
        . as $i
        | ($i.repository.nameWithOwner) as $repo
        | (($i | prs
                | map(select(linkStrength($repo; $i.number) < 9))
                | sort_by(prRank($repo; $i.number)) | first) // null) as $pr
        | (if $pr == null then null
           else ($pr | linkStrength($repo; $i.number)) end) as $link
        | ([ ($i.blockedBy.nodes // [])[] | select(.state == "OPEN") ]) as $blockers
        | (((($i.subIssuesSummary.total) // 0) > 0)
           or (([ $i.labels.nodes[]?.name ] | index("type:parent")) != null)) as $isEpic
        | ($i | status($pr; $blockers; $isEpic)) as $st
        | {
            repo: $i.repository.nameWithOwner,
            number: $i.number,
            url: $i.url,
            title: $i.title,
            state: $i.state,
            updatedAt: $i.updatedAt,
            priority: ($i | priorityOf),
            sprint: ($i | sprintOf),
            isEpic: $isEpic,
            children: { total: (($i.subIssuesSummary.total) // 0),
                        completed: (($i.subIssuesSummary.completed) // 0) },
            parent: (if $i.parent == null then null
                     else { number: $i.parent.number, url: $i.parent.url } end),
            blockedBy: [ $blockers[] | { number, url, repo: .repository.nameWithOwner, title } ],
            blockedByClosed: (((($i.blockedBy.nodes) // []) | length) - ($blockers | length)),
            pr: (if $pr == null then null else {
                   number: $pr.number, url: $pr.url, repo: $pr.repository.nameWithOwner,
                   state: $pr.state, isDraft: $pr.isDraft, merged: $pr.merged,
                   reviewDecision: $pr.reviewDecision,
                   link: ([ "closing", "branch", "title" ][$link]) } end),
            # Pull requests that merely referred to this ticket. Kept for
            # diagnosis, never rendered: a mention is not a claim on the ticket.
            mentionedBy: [ ($i | prs
                                | map(select(linkStrength($repo; $i.number) == 9))
                                | .[] | .url) ],
            prCell: (
              if $pr == null then { text: "—", href: null }
              else
                { text: ("#" + ($pr.number|tostring)
                         + (if $pr.repository.nameWithOwner != $repo
                            then " (" + ($pr.repository.nameWithOwner|split("/")|last) + ")"
                            else "" end)
                         + (if $pr.state != "OPEN" then (if $pr.merged then " merged" else " closed" end)
                            elif $pr.isDraft then " draft" else "" end)),
                  href: $pr.url }
              end),
            status: $st.label,
            statusHref: $st.href,
            sortKeys: { priority: ((priorityRank[($i | priorityOf) // ""]) // 4),
                        status: $st.rank }
          })
    | sort_by(.sortKeys.priority, .sortKeys.status, (.updatedAt | . // "") )
    | reverse | sort_by(.sortKeys.priority, .sortKeys.status)'
}

# -------------------------------------------------------------------- online

cmd_whoami() {
  need gh
  gh api user --jq .login 2>/dev/null || die "no authenticated account; run the host CLI's auth login first"
}

# The board is probed, never assumed. An empty projectItems list is also what a
# token without project scope returns, so absence is only ever reported as unknown.
cmd_board_probe() {
  need gh; need jq
  local out rc=0
  # The probe must ask for a scope-gated field. A bare totalCount answers without
  # the scope and would report the board as readable when its Status is not.
  out=$(gh api graphql -f query='{ viewer { projectsV2(first:1) { nodes { title } } } }' 2>&1) || rc=$?
  if [ "$rc" = 0 ]; then
    jq -n '{ available: true, reason: null }'
  elif printf '%s' "$out" | grep -q 'INSUFFICIENT_SCOPES\|read:project'; then
    jq -n '{ available: false, reason: "the authenticated token has no project-read scope; board Status cannot be read, and an empty project-item list is indistinguishable from no board item" }'
  else
    jq -n --arg r "$(printf '%s' "$out" | head -n 1)" '{ available: false, reason: $r }'
  fi
}

graphql_issues_document() {
  cat <<'EOF'
query($q: String!, $n: Int!, $after: String) {
  search(query: $q, type: ISSUE, first: $n, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on Issue {
        number title url state stateReason updatedAt
        repository { nameWithOwner }
        labels(first: 40) { nodes { name } }
        subIssuesSummary { total completed }
        parent { number url }
        blockedBy(first: 25) { nodes { number url state title repository { nameWithOwner } } }
        closedByPullRequestsReferences(first: 10, includeClosedPrs: true) {
          nodes { number title url state isDraft merged reviewDecision headRefName
                  repository { nameWithOwner } }
        }
        timelineItems(last: 60, itemTypes: [CROSS_REFERENCED_EVENT]) {
          nodes { ... on CrossReferencedEvent { source { ... on PullRequest {
            number title url state isDraft merged reviewDecision headRefName
            repository { nameWithOwner } } } } }
        }
      }
    }
  }
}
EOF
}

graphql_prs_document() {
  cat <<'EOF'
query($q: String!, $n: Int!, $after: String) {
  search(query: $q, type: ISSUE, first: $n, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number title url state isDraft merged updatedAt
        headRefName mergeable mergeStateStatus reviewDecision
        repository { nameWithOwner }
        closingIssuesReferences(first: 10) {
          nodes { number url title state repository { nameWithOwner } }
        }
        reviewThreads(first: 100) { nodes { isResolved isOutdated } }
        commits(last: 1) {
          nodes { commit { statusCheckRollup { state
            contexts(last: 100) {
              nodes {
                ... on CheckRun { name conclusion status }
                ... on StatusContext { context state }
              }
            } } } }
        }
      }
    }
  }
}
EOF
}

# One paged search. Emits the accumulated nodes on stdout and the total count on
# fd 3 so a caller can report truncation without a second round trip.
search_all() {
  local query=$1 doc=$2 cap=$3
  local nodes='[]' after='' page total=0 args
  while :; do
    args=(-F "q=$query" -F n=100 -F "query=@$doc")
    [ -z "$after" ] || args+=(-F "after=$after")
    page=$(gh api graphql "${args[@]}") || return 1
    total=$(printf '%s' "$page" | jq -r '.data.search.issueCount')
    nodes=$(jq -sc 'add' <(printf '%s' "$nodes") \
                         <(printf '%s' "$page" | jq -c '.data.search.nodes | map(select(.number != null))'))
    [ "$(printf '%s' "$nodes" | jq 'length')" -lt "$cap" ] || break
    [ "$(printf '%s' "$page" | jq -r '.data.search.pageInfo.hasNextPage')" = true ] || break
    after=$(printf '%s' "$page" | jq -r '.data.search.pageInfo.endCursor')
  done
  printf '%s' "$total" >"$workdir/total"
  printf '%s' "$nodes" | jq -c ".[:$cap]"
}

cmd_fetch() {
  need gh; need jq
  local login='' cap=$DEFAULT_CAP
  while [ $# -gt 0 ]; do
    case $1 in
      --login) login=${2:?--login needs a value}; shift 2 ;;
      --cap)   cap=${2:?--cap needs a value}; shift 2 ;;
      --)      shift; break ;;
      -*)      die "unknown option for fetch: $1" ;;
      *)       break ;;
    esac
  done

  local filter query prquery
  filter=$(cmd_parse "$@")
  [ -n "$login" ] || login=$(printf '%s' "$filter" | jq -r '.assignee // ""')
  [ -n "$login" ] || login=$(cmd_whoami)
  query=$(printf '%s' "$filter" | cmd_query --login "$login")
  prquery=$(printf '%s' "$filter" | cmd_pr_query --login "$login")

  # The scratch directory is global on purpose: an EXIT trap runs after this
  # function's locals are gone, and would then clean up nothing under set -u.
  workdir=$(mktemp -d) || die "cannot create a temporary directory"
  trap 'rm -rf "${workdir:-}"' EXIT
  graphql_issues_document >"$workdir/issues.graphql"
  graphql_prs_document    >"$workdir/prs.graphql"

  local issueNodes issueTotal prNodes prTotal
  issueNodes=$(search_all "$query" "$workdir/issues.graphql" "$cap") \
    || die "the ticket search failed; the host CLI reported the error above"
  issueTotal=$(cat "$workdir/total")
  prNodes=$(search_all "$prquery" "$workdir/prs.graphql" "$cap") \
    || die "the pull request search failed; the host CLI reported the error above"
  prTotal=$(cat "$workdir/total")

  local rows prRows board
  rows=$(printf '%s' "$issueNodes" | cmd_shape)
  rows=$(printf '%s' "$rows" | jq -c --argjson f "$filter" '
    map(select(
      ($f.epics == "include")
      or ($f.epics == "only"    and .isEpic)
      or ($f.epics == "exclude" and (.isEpic | not))))
    | map(select(($f.blockedOnly | not) or ((.blockedBy | length) > 0)))')
  prRows=$(printf '%s' "$prNodes" | cmd_shape_prs)
  board=$(cmd_board_probe)

  # Sections. Every ticket lands in exactly one, and a ticket already represented
  # by one of my open pull requests is not repeated as a ticket: the pull request
  # row is the more specific answer and carries the next move.
  jq -n --argjson filter "$filter" --argjson rows "$rows" --argjson prs "$prRows" \
        --argjson board "$board" --arg login "$login" \
        --arg query "$query" --arg prquery "$prquery" \
        --argjson matched "$issueTotal" --argjson prMatched "$prTotal" --argjson cap "$cap" '
    ([ $prs[] | .claims[] | (.repo + "#" + (.number|tostring)) ] | unique) as $claimed
    | ($rows | map(
        . as $r
        | ($r.repo + "#" + ($r.number|tostring)) as $key
        | $r + { section:
            (if ($claimed | index($key)) != null then "in-flight"
             elif $r.state == "CLOSED"           then "closed"
             elif $r.isEpic                      then "epic"
             elif ($r.blockedBy | length) > 0    then "waiting"
             elif ($r.pr != null and $r.pr.merged) then "land"
             elif $r.pr != null                  then "in-flight"
             else "next" end) })) as $sectioned
    | { schemaVersion: '"$SCHEMA_VERSION"',
        login: $login,
        filter: $filter,
        searchQuery: $query,
        prSearchQuery: $prquery,
        matched: $matched, returned: ($rows | length), cap: $cap,
        truncated: ($matched > $cap),
        prMatched: $prMatched, prTruncated: ($prMatched > $cap),
        board: $board,
        summary: {
          prsNeedingYou: ([ $prs[] | select(.owner == "you") ] | length),
          prsReadyToMerge: ([ $prs[] | select(.owner == "merge") ] | length),
          prsWaiting: ([ $prs[] | select(.owner == "waiting") ] | length),
          land:    ([ $sectioned[] | select(.section == "land") ]    | length),
          next:    ([ $sectioned[] | select(.section == "next") ]    | length),
          waiting: ([ $sectioned[] | select(.section == "waiting") ] | length),
          epics:   ([ $sectioned[] | select(.section == "epic") ]    | length),
          closed:  ([ $sectioned[] | select(.section == "closed") ]  | length)
        },
        prs: $prs,
        rows: $sectioned }'
}

# ----------------------------------------------------------------------- main

[ $# -gt 0 ] || { usage; exit 2; }
sub=$1; shift
case $sub in
  parse)       cmd_parse "$@" ;;
  query)       cmd_query "$@" ;;
  pr-query)    cmd_pr_query "$@" ;;
  shape)       cmd_shape ;;
  shape-prs)   cmd_shape_prs ;;
  whoami)      cmd_whoami ;;
  board-probe) cmd_board_probe ;;
  fetch)       cmd_fetch "$@" ;;
  -h|--help|help) usage ;;
  *)           die "unknown subcommand: $sub" ;;
esac
