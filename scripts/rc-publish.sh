#!/usr/bin/env bash
set -euo pipefail
policy=$(cd "$(dirname "$0")" && pwd)
. "$policy/rc-release.sh"

[[ $# == 1 ]] || rc_die 'Usage: rc-publish.sh <artifact-directory>'
dist=$(realpath "$1")
tag=${WN_RC_TAG:?}
rc_fetch_tag "$tag"
verified=$(bash "$policy/check-rc-tag.sh" "$tag" "$policy/../packaging/ci/rc-source-signers.asc")
[[ "$verified" == "${WN_CANARY_SHA:?} ${WN_RC_COMMIT:?}" ]] || rc_die 'Tag differs from the stamped source selected for this run'

release=$(rc_api_optional "releases/tags/$tag")
if [[ -n "$release" ]] && jq -e '.draft == false' >/dev/null <<< "$release"; then
  [[ $(jq -er '.tag_name' <<< "$release") == "$tag" ]] || rc_die 'GitHub returned a different tag'
  previous=$(rc_verify_release "$release" "${GITHUB_RUN_ID:?}" "${WN_CANARY_RUN:?}")
  [[ "$previous" == "$verified" ]] || rc_die 'Published RC differs from this run'
  echo "This run already published $tag"
  exit 0
fi

latest=$(rc_api_optional releases/latest)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
notes=$work/notes.md
if [[ -n "$latest" ]]; then
  stable=$(rc_stable_source "$latest")
  git log --format='- %s' "$stable..$WN_CANARY_SHA" > "$notes"
else
  git log -50 --format='- %s' "$WN_CANARY_SHA" > "$notes"
fi

artifacts=(appimage flatpak orchard archlinux cross-linux-arm64 cross-linux-amd64
  cross-windows-amd64 cross-openbsd-amd64 cross-darwin-arm64 cross-darwin-amd64)
download=()
for name in "${artifacts[@]}"; do download+=(-n "$name"); done
gh run download "${GITHUB_RUN_ID:?}" -R "$GITHUB_REPOSITORY" -D "$work/artifacts" "${download[@]}"
mkdir "$dist"
shopt -s nullglob dotglob
for name in "${artifacts[@]}"; do
  files=("$work/artifacts/$name"/*)
  ((${#files[@]} > 0)) || rc_die "Missing artifact: $name"
  for asset in "${files[@]}"; do
    [[ -f "$asset" && ! -L "$asset" ]] || rc_die "Non-file artifact member: $asset"
    file=${asset##*/}
    [[ ! -e "$dist/$file" ]] || rc_die "Duplicate release asset: $file"
    mv -- "$asset" "$dist/$file"
  done
done

cd "$dist"
package=WhiteNoise-$tag
orchard=dev.ipf.whitenoise-linux-x86_64
required=("$package-x86_64.AppImage" "$package-x86_64.AppImage.zsync" "$package-x86_64.flatpak"
  "$package-archlinux-x86_64.tar.zst" "$package-linux-amd64.tar.gz" "$package-linux-arm64.tar.gz"
  "$package-openbsd-amd64.tar.gz" "$package-darwin-amd64.tar.gz" "$package-darwin-arm64.tar.gz"
  appcast-amd64.xml appcast-arm64.xml WhiteNoise-win-Portable.zip releases.win.json assets.win.json
  "WhiteNoise-${tag#v}-full.nupkg"
  "$orchard.asset.json" "$orchard.manifest.json" "$orchard.oci.tgz")
for asset in "${required[@]}"; do
  [[ -s "$asset" ]] || rc_die "Missing or empty release asset: $asset"
done
components=$(jq -er '
  select(.schema == 2 and (.components | length) == 2) | .components | map(.filename) |
  select((unique | length) == 2 and all(test("^[0-9a-f]{64}$"))) | .[]
' "$orchard.asset.json") || rc_die 'Invalid Orchard components'
while read -r component; do
  [[ -s "$component" ]] || rc_die "Missing Orchard component: $component"
done <<< "$components"

globs=('*.AppImage' '*.zsync' '*.flatpak' '*.asset.json' '*.manifest.json'
  '[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*' '*.oci.tgz' '*.tar.gz' '*.tar.zst'
  '*.zip' '*-Setup.exe' '*.nupkg' '*.win.json' 'appcast-*.xml' 'RELEASES')
for glob in "${globs[@]}"; do
  compgen -G "$glob" >/dev/null || rc_die "Missing release assets: $glob"
done
for asset in *; do
  matched=false
  for glob in "${globs[@]}"; do
    if [[ "$asset" == $glob ]]; then matched=true; break; fi
  done
  [[ "$matched" == true ]] || rc_die "Unexpected release asset: $asset"
done
jq -n --arg tag "$tag" --arg canary "$WN_CANARY_SHA" --arg commit "$WN_RC_COMMIT" \
  --argjson canary_run "${WN_CANARY_RUN:?}" --argjson rc_run "${GITHUB_RUN_ID:?}" \
  '{schema:1, tag:$tag, canary_sha:$canary, commit_sha:$commit, canary_run_id:$canary_run, rc_run_id:$rc_run}' > rc-source.json
sha256sum -- * > SHA256SUMS.txt
cat SHA256SUMS.txt

# Velopack 1.2.158 filters prereleases after fetching the first ten releases.
# Leave one slot for this candidate without pushing Latest off that page.
latest=$(rc_api_optional releases/latest)
if [[ -n "$latest" ]]; then
  latest_id=$(jq -er '.id | numbers' <<< "$latest")
  first_nine=$(rc_public_release_ids | sed -n '1,9p')
  grep -Fxq "$latest_id" <<< "$first_nine" ||
    rc_die 'Publishing this candidate could hide Latest from installed Windows updaters. Promote a candidate first.'
fi

# List drafts explicitly: the lookup by tag need not return unpublished releases.
drafts=$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" --jq '.[] | select(.draft == true)' |
  jq -cs --arg tag "$tag" 'map(select(.tag_name == $tag))')
if [[ $(jq 'length' <<< "$drafts") != 0 ]]; then
  draft_id=$(jq -er 'select(length == 1) | .[0] |
    select(.author.login == "github-actions[bot]" and .author.id == 41898282) | .id' <<< "$drafts") ||
    rc_die "Unexpected draft owners or multiple drafts for $tag"
  draft=$(gh api "repos/$GITHUB_REPOSITORY/releases/$draft_id")
  jq -e --arg tag "$tag" '.draft == true and .tag_name == $tag and .author.id == 41898282' >/dev/null <<< "$draft" ||
    rc_die "Draft changed before cleanup: $tag"
  gh api -X DELETE "repos/$GITHUB_REPOSITORY/releases/$draft_id"
fi

gh release create "$tag" ./* -R "$GITHUB_REPOSITORY" --verify-tag --prerelease --latest=false \
  --title "White Noise $tag" --notes-file "$notes"
release=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$tag")
jq -e --arg tag "$tag" '.tag_name == $tag and .draft == false and .prerelease == true and .immutable == true' \
  >/dev/null <<< "$release" || rc_die "GitHub did not publish an immutable prerelease: $tag"
