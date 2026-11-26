#!/usr/bin/env bash
# Release API and provenance checks. Call with trusted $policy and an isolated Git repo.
. "$policy/rc-source.sh"

rc_api_optional() {
  local response protocol code rest status=0
  response=$(gh api --include "repos/$GITHUB_REPOSITORY/$1") || status=$?
  read -r protocol code rest <<< "$response"
  [[ "$protocol" == HTTP/* ]] || return 1
  if [[ "$code" == 404 ]]; then return 0; fi
  [[ "$code" == 200 && "$status" == 0 ]] || return 1
  awk 'body {print; next} /^\r?$/ {body=1}' <<< "$response"
}

rc_public_release_ids() {
  gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
    --jq '.[] | select(.draft == false) | .id'
}

rc_fetch_tag() {
  bash "$policy/version.sh" --tag "$1" >/dev/null || return
  git fetch --no-tags origin "refs/tags/$1:refs/tags/$1" >&2
}

rc_has_provenance() {
  jq -e 'any(.assets[]; .name == "rc-source.json")' >/dev/null <<< "$1"
}

rc_verify_release() (
  release=$1
  tag=$(jq -er '.tag_name' <<< "$release") || return
  jq -e '.draft == false and .immutable == true and
    ([.assets[] | select(.name == "rc-source.json")] | length == 1)' >/dev/null <<< "$release" ||
    rc_die "Expected a public immutable RC with provenance: $tag"
  verified=$(bash "$policy/check-rc-tag.sh" "$tag" "$policy/../packaging/ci/rc-source-signers.asc") || return
  read -r canary commit <<< "$verified"
  tmp=$(mktemp -d) || return
  trap 'rm -rf "$tmp"' EXIT
  gh release download "$tag" -R "$GITHUB_REPOSITORY" -p rc-source.json -D "$tmp" || return
  gh release verify-asset "$tag" "$tmp/rc-source.json" -R "$GITHUB_REPOSITORY" >&2 || return
  jq -es --arg tag "$tag" --arg canary "$canary" --arg commit "$commit" \
    --argjson rc_run "${2:-null}" --argjson canary_run "${3:-null}" '
    length == 1 and (.[0] | .schema == 1 and .tag == $tag and
      .canary_sha == $canary and .commit_sha == $commit and
      ([.canary_run_id, .rc_run_id] | all(type == "number" and . > 0 and . == floor)) and
      ($rc_run == null or .rc_run_id == $rc_run) and
      ($canary_run == null or .canary_run_id == $canary_run))
  ' "$tmp/rc-source.json" >/dev/null || rc_die "RC provenance does not match the signed tag: $tag"
  printf '%s %s\n' "$canary" "$commit"
)

rc_stable_source() {
  local release=$1 tag verified canary commit
  tag=$(jq -er '.tag_name' <<< "$release") || return
  rc_fetch_tag "$tag" || return
  if rc_has_provenance "$release"; then
    verified=$(rc_verify_release "$release") || return
    read -r canary commit <<< "$verified"
    printf '%s\n' "$canary"
    return
  fi
  if [[ $(git for-each-ref --format='%(contents:subject)' "refs/tags/$tag") == 'White Noise RC' ]]; then
    rc_die "Stable RC has no provenance: $tag"
  fi
  git rev-parse --verify "refs/tags/$tag^{commit}"
}
