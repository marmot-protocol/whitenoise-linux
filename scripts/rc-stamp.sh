#!/usr/bin/env bash
set -euo pipefail
export GIT_NO_REPLACE_OBJECTS=1
export -n signing_key
signing_key=${WN_RC_GIT_SIGNING_KEY:-}
unset WN_RC_GIT_SIGNING_KEY
policy=$(cd "$(dirname "$0")" && pwd)
. "$policy/rc-source.sh"

[[ $# == 2 ]] || rc_die 'Usage: rc-stamp.sh <canary-sha> <utc-date>'
canary=$1 date=$2
[[ "$canary" =~ ^[a-f0-9]{40}$ && $(git cat-file -t "$canary") == commit ]] || rc_die 'Invalid Canary commit'
day=$(bash "$policy/version.sh" --date "$date")
key="$policy/../packaging/ci/rc-source-signers.asc"

existing=$(rc_reservation "$canary")
if [[ -n "$existing" ]]; then
  [[ "$existing" != *$'\n'* ]] || rc_die 'Multiple RC reservations for this Canary'
  verified=$(bash "$policy/check-rc-tag.sh" "$existing" "$key")
  read -r parent commit <<< "$verified"
  [[ "$parent" == "$canary" ]] || rc_die 'Reserved tag names the wrong Canary'
  printf '%s %s\n' "$existing" "$commit"
  exit 0
fi

[[ $(git rev-parse HEAD) == "$canary" ]] || rc_die 'Check out the exact Canary commit before stamping'
if git symbolic-ref -q HEAD >/dev/null; then rc_die 'Detach HEAD before stamping'; fi
[[ -z $(git status --porcelain) ]] || rc_die 'The stamp checkout must be clean'
export WN_VERSION_ROOT="$PWD"
current=$(bash "$policy/version.sh")
revisions=$(git tag -l "v$day-build.*")
if [[ "${current%+*}" == "$day" ]]; then revisions+=$'\n'"v${current/+/-build.}"; fi
revision=$(awk -v prefix="v$day-build." 'index($0, prefix) == 1 {
  r = substr($0, length(prefix) + 1); if (r ~ /^[1-9][0-9]*$/) print r
}' <<< "$revisions" | LC_ALL=C sort -V | tail -n 1)
revision=${revision:-0}
zeros=
while [[ "$revision" == *9 ]]; do revision=${revision%9}; zeros+=0; done
revision=${revision:-0}
revision="${revision%?}$((${revision: -1} + 1))$zeros"
version="$day+$revision"
tag="v$day-build.$revision"

paths=(app/advanced.odin assets/whitenoise-linux.metainfo.xml)
for path in "${paths[@]}"; do
  rc_edit "$path" "$version" "$date" < "$path" > "$path.tmp"
  cat "$path.tmp" > "$path"
  rm "$path.tmp"
done
bash "$policy/version.sh" "$tag" >/dev/null

# The public fingerprint identifies the only key allowed to sign. The secret
# stays in this subshell and never reaches packaging or the tag push.
(
  export GNUPGHOME
  GNUPGHOME=$(mktemp -d)
  trap 'rc_gpg_cleanup "$GNUPGHOME"' EXIT
  primary=$(rc_fingerprint "$key") || rc_die 'Expected one release-source OpenPGP public key'
  printf '%s\n' "${signing_key:?Missing release-source signing key}" | gpg --batch --quiet --import
  unset signing_key
  gpg --batch --list-secret-keys "$primary" >/dev/null
  git -c core.hooksPath=/dev/null -c gpg.format=openpgp -c gpg.openpgp.program=gpg \
    commit -q -S"$primary" -m "Stamp White Noise $version" -- "${paths[@]}"
  git -c gpg.format=openpgp -c gpg.openpgp.program=gpg \
    tag -s -u "$primary" -m 'White Noise RC' -m "Canary-SHA: $canary" "$tag"
)
unset signing_key
verified=$(bash "$policy/check-rc-tag.sh" "$tag" "$key")
read -r parent commit <<< "$verified"
[[ "$parent" == "$canary" ]] || rc_die 'New tag names the wrong Canary'
printf '%s %s\n' "$tag" "$commit"
