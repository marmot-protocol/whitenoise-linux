#!/usr/bin/env bash
set -euo pipefail

fail() { echo "$*" >&2; exit 1; }

is_ancestor() {
  local status=0
  git merge-base --is-ancestor "$1" "$2" || status=$?
  if ((status > 1)); then fail "Cannot compare ancestry: $1 $2"; fi
  return "$status"
}

list_runs() {
  local event=$1 sha=$2
  shift 2
  gh api --paginate -X GET "repos/$GITHUB_REPOSITORY/actions/workflows/ci.yml/runs" \
    -f event="$event" -f branch=master -f head_sha="$sha" -F per_page=100 "$@" \
    --jq '.workflow_runs[] | [.id, .status, .check_suite_node_id] | @tsv'
}

find_job_run() {
  local job=$1 mode=$2 runs=$3 id suite row proofs
  local -a batch
  local query='query($ids: [ID!]!, $job: String!, $conclusions: [CheckConclusionState!]!) {
    nodes(ids: $ids) { ... on CheckSuite { id
      checkRuns(first: 1, filterBy: {checkName: $job, checkType: ALL, conclusions: $conclusions}) {
        nodes { name }
      }
    } }
  }'
  # The first run on a SHA usually did the build. Later runs may all be skips.
  runs=$(tac <<< "$runs" | awk -F '\t' -v mode="$mode" -v current="${GITHUB_RUN_ID:-}" '
    $3 != "" && (mode != "completed" || ($2 == "completed" && $1 != current)) { print }
  ') || return
  [[ -n "$runs" ]] || return 0
  # Batch check suites to stay within the token quota during long quiet periods.
  while mapfile -t -n 40 batch && ((${#batch[@]})); do
    proofs=$(printf '%s\n' "${batch[@]}" |
      jq -Rcn --arg query "$query" --arg job "$job" --arg mode "$mode" '
        {query: $query, variables: {
          ids: [inputs | split("\t") | .[2]], job: $job,
          conclusions: (if $mode == "completed" then ["SUCCESS", "FAILURE"] else ["SUCCESS"] end)
        }}' |
      gh api graphql --input - |
      jq -r --arg job "$job" '.data.nodes[] | select(any(.checkRuns.nodes[]?; .name == $job)) | .id') || return
    for row in "${batch[@]}"; do
      suite=${row##*$'\t'}
      if grep -Fxq "$suite" <<< "$proofs"; then
        id=${row%%$'\t'*}
        printf '%s\n' "$id"
        return
      fi
    done
  done <<< "$runs"
}

find_run() {
  local sha=$1 job=$2 mode=$3 event runs proof created start end now window=$((14 * 86400))
  for event in workflow_dispatch schedule; do
    runs=$(list_runs "$event" "$sha") || return
    if [[ $(wc -l <<< "$runs") -lt 1000 ]]; then
      proof=$(find_job_run "$job" "$mode" "$runs") || return
      if [[ -n "$proof" ]]; then printf '%s\n' "$proof"; return; fi
      continue
    fi

    # GitHub caps a filtered search at 1,000 runs. At one run per hour,
    # each 14-day window fits even if master does not change for months.
    created=$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/ci.yml" --jq .created_at) || return
    start=$(date -u -d "$created" +%s) || return
    now=$(date -u +%s) || return
    while ((start <= now)); do
      end=$((start + window - 1))
      created="$(date -u -d "@$start" +%FT%TZ)..$(date -u -d "@$end" +%FT%TZ)"
      runs=$(list_runs "$event" "$sha" -f created="$created") || return
      if [[ $(wc -l <<< "$runs") -ge 1000 ]]; then fail "Too many $event runs in $created"; fi
      proof=$(find_job_run "$job" "$mode" "$runs") || return
      if [[ -n "$proof" ]]; then printf '%s\n' "$proof"; return; fi
      start=$((end + 1))
    done
  done
}

[[ $# == 1 && "$1" =~ ^(select|advance|green)$ ]] || fail 'Usage: canary.sh select|advance|green'
mode=$1
refs=$(git ls-remote --refs origin refs/heads/master refs/heads/canary)
master=$(awk '$2 == "refs/heads/master" {print $1}' <<< "$refs")
canary=$(awk '$2 == "refs/heads/canary" {print $1}' <<< "$refs")
[[ "$master" =~ ^[a-f0-9]{40}$ ]] || fail 'GitHub master is missing'
revs=("$master")
if [[ -n "$canary" ]]; then revs+=("$canary"); fi
git fetch --no-tags origin "${revs[@]}"
[[ $(git rev-parse --is-shallow-repository) == false ]] || fail 'Canary needs complete history'

if [[ "$mode" == green ]]; then
  if [[ -z "$canary" ]]; then echo 'No Canary ref'; exit 0; fi
  is_ancestor "$canary" "$master" || fail 'Canary is not in GitHub master history'
  proof=$(find_run "$canary" 'Advance Canary' green)
  if [[ -z "$proof" ]]; then echo 'Canary has no green run'; exit 0; fi
  printf 'Green Canary: %s (CI run %s)\n' "$canary" "$proof"
  printf 'canary_sha=%s\ncanary_run_id=%s\n' "$canary" "$proof" >> "$GITHUB_OUTPUT"
  exit 0
fi

sha=$(git rev-parse HEAD)
[[ "$sha" == "$GITHUB_SHA" ]] || fail 'Canary checkout differs from the event SHA'
if ! is_ancestor "$sha" "$master"; then
  [[ "$mode" == select ]] || fail 'Event SHA is no longer on GitHub master'
  echo 'Canary skip: event SHA is no longer on GitHub master'
  exit 0
fi
if [[ -n "$canary" ]] && ! is_ancestor "$canary" "$sha"; then
  if [[ "$mode" == select ]] && is_ancestor "$sha" "$canary"; then
    echo 'Canary skip: event SHA is behind Canary'
    exit 0
  fi
  fail 'Canary cannot fast-forward to the event SHA'
fi

if [[ "$mode" == select ]]; then
  if [[ "$canary" == "$sha" ]]; then
    proof=$(find_run "$sha" 'Advance Canary' green)
    if [[ -n "$proof" ]]; then echo 'Canary already green'; exit 0; fi
  fi
  if [[ "$GITHUB_EVENT_NAME" == schedule ]]; then
    previous=$(find_run "$sha" 'build + test' completed)
    if [[ -n "$previous" ]]; then echo "Canary skip: run $previous already tested this SHA"; exit 0; fi
  fi
  echo 'build=true' >> "$GITHUB_OUTPUT"
  exit 0
fi

if [[ -z "$canary" ]]; then
  updated=$(gh api -X POST "repos/$GITHUB_REPOSITORY/git/refs" -f ref=refs/heads/canary -f sha="$sha" --jq .object.sha)
elif [[ "$canary" != "$sha" ]]; then
  updated=$(gh api -X PATCH "repos/$GITHUB_REPOSITORY/git/refs/heads/canary" -f sha="$sha" -F force=false --jq .object.sha)
else
  updated=$canary
fi
[[ "$updated" == "$sha" ]] || fail 'GitHub returned an unexpected Canary SHA'
printf 'Canary: %s\n' "$sha"
