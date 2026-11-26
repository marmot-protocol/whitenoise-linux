#!/usr/bin/env bash
set -euo pipefail
policy=$(cd "$(dirname "$0")" && pwd)
. "$policy/rc-release.sh"

[[ $# == 1 && "$1" =~ ^[a-f0-9]{40}$ ]] || rc_die 'Usage: rc-select.sh <canary-sha>'
canary=$1

if ! git cat-file -e "$canary:scripts/aur-render.sh"; then
  echo 'Waiting for a green Canary with RC packaging support'
  exit 0
fi

existing=$(rc_reservation "$canary")
if [[ -n "$existing" ]]; then
  [[ "$existing" != *$'\n'* ]] || rc_die 'Multiple RC reservations for this Canary'
  verified=$(bash "$policy/check-rc-tag.sh" "$existing" "$policy/../packaging/ci/rc-source-signers.asc")
  read -r parent commit <<< "$verified"
  [[ "$parent" == "$canary" ]] || rc_die 'Reserved tag names the wrong Canary'
  release=$(rc_api_optional "releases/tags/$existing")
  if [[ -n "$release" ]] && jq -e '.draft == false' >/dev/null <<< "$release"; then
    rc_verify_release "$release" >/dev/null
    echo "Canary already published as $existing"
    exit 0
  fi
fi

staged=$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" --jq '
  .[] | select(.draft == false and .immutable == true and any(.assets[]; .name == "rc-source.json")) | .tag_name')
if [[ -n "$staged" ]]; then
  newest=$(LC_ALL=C sort -V <<< "$staged" | tail -n 1)
  rc_fetch_tag "$newest"
  release=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$newest")
  verified=$(rc_verify_release "$release")
  read -r parent commit <<< "$verified"
  status=0
  git merge-base --is-ancestor "$canary" "$parent" || status=$?
  if ((status == 0)); then
    echo "Canary is already covered by $newest"
    exit 0
  elif ((status > 1)); then
    rc_die 'Cannot compare Canary with the latest published candidate'
  fi
fi

[[ -s "$policy/../packaging/ci/rc-source-signers.asc" ]] || rc_die 'Install the release-source public key in trusted master'
echo 'stamp=true' >> "$GITHUB_OUTPUT"
