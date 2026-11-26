#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
export GNUPGHOME="$tmp/gnupg"
trap 'gpgconf --kill gpg-agent; rm -rf "$tmp"' EXIT
mkdir -m 700 "$GNUPGHOME"
mkdir -p "$tmp/policy/scripts" "$tmp/policy/packaging/ci"
cp "$root/scripts/"{version,rc-source,rc-stamp,check-rc-tag}.sh "$tmp/policy/scripts/"
policy="$tmp/policy/scripts"
key="$tmp/policy/packaging/ci/rc-source-signers.asc"
gpg --batch --passphrase '' --quick-generate-key 'RC fixture <rc@example.test>' ed25519 sign 0
gpg --batch --armor --export rc@example.test > "$key"
signing_key=$(gpg --batch --armor --export-secret-keys rc@example.test)

git init -q --bare "$tmp/mirror"
git init -q -b master "$tmp/source"
cd "$tmp/source"
git config core.hooksPath /dev/null
git config user.name Fixture
git config user.email rc@example.test
git config user.signingkey rc@example.test
git config gpg.format openpgp
git config gpg.program gpg
git remote add origin "$tmp/mirror"
mkdir app assets scripts
cp "$root/scripts/version.sh" scripts/
printf 'APP_VERSION :: "2026.11.25+1" // preserve this\n' > app/advanced.odin
printf '<component>\n  <releases>\n  </releases>\n</component>\n' > assets/whitenoise-linux.metainfo.xml
git add .
git -c commit.gpgsign=false commit -qm Base
base=$(git rev-parse HEAD)
git -c commit.gpgsign=false commit --allow-empty -qm Canary
canary=$(git rev-parse HEAD)
git tag --no-sign v2026.11.25-build.2 "$base"
git push -q origin master refs/tags/v2026.11.25-build.2 "$canary:refs/heads/canary"
git switch -q --detach "$canary"

first=$(WN_RC_GIT_SIGNING_KEY="$signing_key" bash "$policy/rc-stamp.sh" "$canary" 2026-11-25)
read -r tag commit <<< "$first"
[[ "$tag" == v2026.11.25-build.3 ]]
[[ $(bash "$policy/check-rc-tag.sh" "$tag" "$key") == "$canary $commit" ]]
[[ $(git diff --name-only "$canary" "$commit") == $'app/advanced.odin\nassets/whitenoise-linux.metainfo.xml' ]]
git push -q origin "refs/tags/$tag:refs/tags/$tag"
mkdir "$tmp/archive"
git archive "$commit" | tar -x -C "$tmp/archive"
[[ $(bash "$tmp/archive/scripts/version.sh" "$tag") == '2026.11.25+3' ]]
grep -Fx '    <release version="2026.11.25+3" date="2026-11-25"/>' "$tmp/archive/assets/whitenoise-linux.metainfo.xml"
[[ $(git rev-parse master) == "$canary" ]]
[[ $(git --git-dir="$tmp/mirror" rev-parse master) == "$canary" ]]

git init -q "$tmp/retry"
cd "$tmp/retry"
git remote add origin "$tmp/mirror"
git fetch -q --tags origin master canary
git switch -q --detach "$canary"
[[ $(bash "$policy/rc-stamp.sh" "$canary" 2026-11-26) == "$first" ]]

cd "$tmp/source"
# A valid signature does not make a wrong parent or a non-stamp diff valid.
reject_stamp() {
  local refs
  refs=$(git show-ref)
  if bash "$policy/rc-stamp.sh" "$canary" 2026-11-26; then
    echo 'Invalid reservation was accepted' >&2
    exit 1
  fi
  [[ $(git show-ref) == "$refs" ]]
}

git tag -d "$tag" >/dev/null
bad=v2026.11.25-build.4
git tag -s -m 'White Noise RC' -m "Canary-SHA: $canary" "$bad" "$base"
reject_stamp
git tag -d "$bad" >/dev/null

git switch -q --detach "$canary"
printf 'APP_VERSION :: "2026.11.25+4" // preserve this\n' > app/advanced.odin
printf '<component>\n  <releases>\n    <release version="2026.11.25+4" date="2026-11-25"/>\n  </releases>\n</component>\n' > assets/whitenoise-linux.metainfo.xml
printf 'unrelated\n' > extra
git add app assets extra
git commit -q -S -m 'Stamp White Noise 2026.11.25+4'
git tag -s -m 'White Noise RC' -m "Canary-SHA: $canary" "$bad"
reject_stamp
git tag -d "$bad" >/dev/null

git rm -q extra
printf '// unrelated\n' >> app/advanced.odin
git add app/advanced.odin
git commit -q -S --amend --no-edit
git tag -s -m 'White Noise RC' -m "Canary-SHA: $canary" "$bad"
reject_stamp
git fetch -q origin "refs/tags/$tag:refs/tags/$tag"
reject_stamp
printf 'RC stamp fixtures passed\n'
