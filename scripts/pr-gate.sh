#!/usr/bin/env bash
set -euo pipefail
export GIT_NO_REPLACE_OBJECTS=1

emit_lane() {
  printf 'lane=%s\n' "$1" >> "${GITHUB_OUTPUT:?}"
  printf 'PR gate: %s lane\n' "$1"
  exit 0
}

[[ $# == 2 ]] || { echo 'Usage: pr-gate.sh <base-sha> <head-sha>' >&2; exit 2; }
base=$1 head=$2
if [[ ! "$base" =~ ^[a-f0-9]{40}$ || ! "$head" =~ ^[a-f0-9]{40}$ ]] ||
   [[ $(git rev-parse --is-shallow-repository) != false ]] ||
   [[ $(git cat-file -t "$base") != commit || $(git cat-file -t "$head") != commit ]] ||
   ! git merge-base "$base" "$head" >/dev/null; then
  emit_lane build
fi

commits=$(git rev-list "$head" --not "$base") || emit_lane build
[[ -n "$commits" ]] || emit_lane build
policy_paths=(.github/workflows/ .ngit/ .githooks/ scripts/pr-gate.sh packaging/ci/)
changes=$(git diff --no-renames --name-only "$base...$head" -- "${policy_paths[@]}") || emit_lane build
[[ -z "$changes" ]] || emit_lane build

export GNUPGHOME
GNUPGHOME=$(mktemp -d)
trap 'rm -rf "$GNUPGHOME"' EXIT
key_file=$(dirname "$0")/../packaging/ci/team-signers.asc
gpg --batch --import "$key_file" || emit_lane build

# Check every signature before requiring evidence on any commit. A mixed-key
# proposal takes the build lane even if an earlier trusted commit lacks trailers.
while IFS= read -r sha; do
  changes=$(git diff-tree -m -r --root --no-renames --no-commit-id --name-only "$sha" -- "${policy_paths[@]}") || emit_lane build
  [[ -z "$changes" ]] || emit_lane build
  if ! status=$(git -c gpg.format=openpgp -c gpg.program=gpg -c gpg.openpgp.program=gpg verify-commit --raw "$sha" 2>&1) ||
     ! grep -q '^\[GNUPG:\] VALIDSIG ' <<< "$status" ||
     grep -Eq '^\[GNUPG:\] (BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG) ' <<< "$status"; then
    emit_lane build
  fi
done <<< "$commits"

while IFS= read -r sha; do
  trailers=$(git show -s --format=%B "$sha" | git interpret-trailers --parse)
  if ! awk -F: '
    tolower($1) == "local-checks" { checks++; if ($0 !~ /:[[:space:]]*[^[:space:]]/) bad = 1 }
    tolower($1) == "local-review" { reviews++; if ($0 !~ /:[[:space:]]*[^[:space:]]/) bad = 1 }
    END { exit !(checks == 1 && reviews == 1 && !bad) }
  ' <<< "$trailers"; then
    echo "::error::Commit $sha needs exactly one nonempty Local-Checks and Local-Review trailer." >&2
    exit 1
  fi
done <<< "$commits"
emit_lane static
