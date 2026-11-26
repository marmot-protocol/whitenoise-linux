#!/usr/bin/env bash
set -euo pipefail
policy=$(cd "$(dirname "$0")" && pwd)
. "$policy/rc-release.sh"

[[ $# == 1 ]] || rc_die 'Usage: scripts/release.sh <tag>'
tag=$1
bash "$policy/version.sh" --tag "$tag" >/dev/null
export GITHUB_REPOSITORY=marmot-protocol/whitenoise-linux
ngit=nostr://cyberguy.fyi/relay.ngit.dev/darkmatter-linux
root=$(cd "$policy/.." && pwd)
for direction in '' --push; do
  [[ $(git -C "$root" remote get-url ${direction:+"$direction"} origin) == "$ngit" ]] ||
    rc_die 'origin must point to the canonical ngit repository'
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q "$tmp"
cd "$tmp"
git remote add origin "https://github.com/$GITHUB_REPOSITORY.git"
git remote add ngit "$ngit"
rc_fetch_tag "$tag"
verified=$(bash "$policy/check-rc-tag.sh" "$tag" "$policy/../packaging/ci/rc-source-signers.asc")
read -r canary commit <<< "$verified"
git fetch --no-tags ngit refs/heads/master
git merge-base --is-ancestor "$canary" FETCH_HEAD || rc_die 'Canary is not on ngit origin/master'

release=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$tag")
jq -e --arg tag "$tag" '.tag_name == $tag and .immutable == true and .draft == false' >/dev/null <<< "$release" ||
  rc_die "Not a public immutable release: $tag"

ref=refs/tags/$tag
tag_object=$(git rev-parse "$ref")
expected=$tag_object$'\t'"$ref"
actual=$(git ls-remote --refs ngit "$ref")
if [[ -z "$actual" ]]; then
  # Import the verified objects without updating local refs. Push from the
  # maintainer's checkout so ngit can use its repository-local signer.
  git -C "$root" fetch --no-tags --no-write-fetch-head "$tmp" "$ref"
  git -C "$root" push --no-follow-tags origin "$tag_object:$ref"
  actual=$(git ls-remote --refs ngit "$ref")
fi
[[ "$actual" == "$expected" ]] || rc_die "ngit tag differs from the signed GitHub tag: $tag"
gh workflow run promote.yml --ref master -R "$GITHUB_REPOSITORY" -f tag="$tag"
printf 'Queued promotion for %s.\n' "$tag"
