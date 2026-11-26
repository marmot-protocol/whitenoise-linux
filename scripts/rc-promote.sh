#!/usr/bin/env bash
set -euo pipefail
export GIT_NO_REPLACE_OBJECTS=1
policy=$(cd "$(dirname "$0")" && pwd)
. "$policy/rc-release.sh"

[[ $# == 1 ]] || rc_die 'Usage: rc-promote.sh <tag>'
tag=$1
rc_fetch_tag "$tag"
release=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$tag")
[[ $(jq -er '.tag_name' <<< "$release") == "$tag" ]] || rc_die 'GitHub returned a different tag'
verified=$(rc_verify_release "$release")
read -r canary commit <<< "$verified"

ref=refs/tags/$tag
expected=$(git rev-parse "$ref")
identifier=darkmatter-linux
repo=nostr://npub1ven4zk8xxw873876gx8y9g9l9fazkye9qnwnglcptgvfwxmygscqsxddfh/relay.ngit.dev/$identifier
roster=$(ngit --repo "$repo" repo --json)
maintainers=$(jq -er --arg d "$identifier" '
  select(.is_nostr_repo == true and .identifier == $d and .health.status == "ok") |
  .confirmed_maintainers[] | select(test("^npub1[0-9a-z]{58}$"))' <<< "$roster")
authors=$(while IFS= read -r npub; do nak decode "$npub" || exit; done <<< "$maintainers" | jq -Rcs '
  split("\n") | map(select(length > 0)) | select(length > 0 and all(test("^[a-f0-9]{64}$")))')
# ls-remote can fall back to a Git replica with no signed state.
state=$(jq -nc --arg d "$identifier" --argjson authors "$authors" \
    '{kinds:[30618], "#d":[$d], authors:$authors}' |
  timeout 40 nak req wss://relay.ngit.dev wss://relay.cyberguy.fyi wss://gitnostr.com |
  jq -ces --arg d "$identifier" --argjson authors "$authors" '
    map(select(.kind == 30618 and (.pubkey as $p | $authors | index($p) != null) and
      [.tags[] | select(.[0] == "d") | .[1]] == [$d])) |
    sort_by(-.created_at, .id) | .[0]') || rc_die 'Cannot read signed ngit state'
nak verify <<< "$state" || rc_die 'Invalid ngit state signature'
jq -e --arg ref "$ref" --arg oid "$expected" \
  '[.tags[] | select(.[0] == $ref)] == [[$ref, $oid]]' >/dev/null <<< "$state" ||
  rc_die "Signed ngit state lacks the identical tag: $tag"
advertised=$(git ls-remote --refs "$repo" "$ref")
[[ "$advertised" == "$expected"$'\t'"$ref" ]] || rc_die "ngit does not advertise the identical tag: $tag"

asset_identity() {
  jq -ceS 'select((.id | type) == "number" and
    all(.assets[]; (.id | type) == "number" and (.digest | test("^sha256:[a-f0-9]{64}$")))) |
    {id, tag_name, assets: (.assets | map({id, digest}) | sort_by(.id))}' <<< "$1"
}

identity=$(asset_identity "$release") || rc_die "Release assets have no digest: $tag"
release_id=$(jq -er '.id' <<< "$identity")
latest=$(rc_api_optional releases/latest)
latest_tag=
if [[ -n "$latest" ]]; then
  jq -e '.draft == false and .prerelease == false' >/dev/null <<< "$latest" || rc_die 'Invalid GitHub Latest metadata'
  latest_tag=$(jq -er '.tag_name' <<< "$latest")
fi

if [[ "$latest_tag" != "$tag" ]]; then
  jq -e '.prerelease == true' >/dev/null <<< "$release" || rc_die "Already stable but not Latest: $tag"
  if [[ -n "$latest_tag" ]]; then
    stable=$(rc_stable_source "$latest")
    highest=$(printf '%s\n' "$latest_tag" "$tag" | LC_ALL=C sort -V | tail -n 1)
    [[ "$highest" == "$tag" ]] || rc_die "$tag is older than Latest ($latest_tag)"
    git merge-base --is-ancestor "$stable" "$canary" || rc_die 'Selected Canary does not contain the Stable source'
  fi
  first_ten=$(rc_public_release_ids | sed -n '1,10p')
  grep -Fxq "$release_id" <<< "$first_ten" ||
    rc_die "$tag is outside the release page read by installed Windows updaters"
  gh api -X PATCH "repos/$GITHUB_REPOSITORY/releases/$release_id" -F prerelease=false -f make_latest=true >/dev/null
else
  echo "$tag is already Latest"
fi

latest=$(gh api "repos/$GITHUB_REPOSITORY/releases/latest")
jq -e '.immutable == true and .draft == false and .prerelease == false' >/dev/null <<< "$latest" ||
  rc_die 'Latest is not public immutable Stable'
[[ $(asset_identity "$latest") == "$identity" ]] || rc_die 'Latest release ID, tag, or asset identities changed'
printf 'tag=%s\nrelease_id=%s\ncommit_sha=%s\n' "$tag" "$release_id" "$commit" >> "$GITHUB_OUTPUT"
