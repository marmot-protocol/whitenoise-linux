#!/usr/bin/env bash
set -euo pipefail
export GIT_NO_REPLACE_OBJECTS=1
policy=$(cd "$(dirname "$0")" && pwd)
. "$policy/rc-source.sh"

[[ $# == 2 ]] || rc_die 'Usage: check-rc-tag.sh <tag> <public-key-file>'
tag=$1 key=$2
parsed=$(bash "$policy/version.sh" --tag "$tag")
read -r version date <<< "$parsed"
ref=refs/tags/$tag
[[ $(git cat-file -t "$ref") == tag ]] || rc_die "Expected an annotated RC tag: $tag"
# The signed tag names one commit directly and cannot identify another ref.
read -r object_type commit embedded_tag < <(git for-each-ref --format='%(*objecttype) %(*objectname) %(tag)' "$ref")
[[ "$object_type" == commit && "$embedded_tag" == "$tag" ]] || rc_die "RC tag object does not match $tag"
[[ $(git for-each-ref --format='%(contents:subject)' "$ref") == 'White Noise RC' ]] || rc_die "Not an RC reservation: $tag"
trailers=$(git for-each-ref --format='%(contents:trailers:key=Canary-SHA,only,valueonly)' "$ref")
[[ "$trailers" =~ ^[a-f0-9]{40}$ ]] || rc_die "Expected one Canary-SHA trailer in $tag"
canary=$trailers
[[ $(git show -s --format=%P "$commit") == "$canary" ]] || rc_die "RC parent differs from the Canary SHA in $tag"
[[ $(git show -s --format=%s "$commit") == "Stamp White Noise $version" ]] || rc_die "Invalid stamp subject: $tag"

export GNUPGHOME
GNUPGHOME=$(mktemp -d)
trap 'rc_gpg_cleanup "$GNUPGHOME"' EXIT
primary=$(rc_fingerprint "$key") || rc_die 'Expected one release-source OpenPGP public key'
gpg --batch --quiet --import "$key"
rc_signed_by tag "$ref" "$primary" || rc_die "Invalid release-source tag signature: $tag"
rc_signed_by commit "$commit" "$primary" || rc_die "Invalid release-source commit signature: $commit"

paths=(app/advanced.odin assets/whitenoise-linux.metainfo.xml)
changes=$(git diff --no-ext-diff --no-renames --name-only "$canary" "$commit")
[[ "$changes" == "$(printf '%s\n' "${paths[@]}")" ]] || rc_die "RC stamp changed an unexpected file: $tag"
[[ -z $(git diff --no-ext-diff --no-renames --summary "$canary" "$commit") ]] || rc_die "RC stamp changed a file mode: $tag"
anchors=('^APP_VERSION :: "' '^  <releases>$')
for i in "${!paths[@]}"; do
  path=${paths[i]}
  count=$(git show "$canary:$path" | grep -c "${anchors[i]}") || rc_die "Missing stamp anchor: $path"
  [[ "$count" == 1 ]] || rc_die "Ambiguous stamp anchor: $path"
  expected=$(git show "$canary:$path" | rc_edit "$path" "$version" "$date" | git hash-object --stdin)
  original=$(git rev-parse "$canary:$path")
  actual=$(git rev-parse "$commit:$path")
  [[ "$actual" == "$expected" && "$actual" != "$original" ]] || rc_die "Invalid RC edit: $path"
done
printf '%s %s\n' "$canary" "$commit"
