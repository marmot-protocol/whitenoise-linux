#!/usr/bin/env bash
# Exercise the interactive publisher against local Git remotes, never GitHub.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
export GNUPGHOME="$WORK/gnupg"
cleanup() {
  gpgconf --kill gpg-agent
  rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -m 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key 'Release test <release@example.invalid>' ed25519 sign 0
KEY="$(gpg --batch --with-colons --list-keys release@example.invalid | awk -F: '$1 == "fpr" { print $10; exit }')"

CHECKOUT="$WORK/checkout"
git init -q -b master "$CHECKOUT"
cd "$CHECKOUT"
git config user.name 'Release test'
git config user.email release@example.invalid
git config user.signingkey "$KEY"
git config commit.gpgsign true
git config tag.gpgsign true
git config gpg.format openpgp
git config gpg.program gpg
mkdir scripts app assets
cp "$HERE/scripts/"{release,publish,version}.sh scripts/
printf 'APP_VERSION :: "2000.1.1+1"\n' >app/advanced.odin
printf '<component>\n  <releases>\n  </releases>\n</component>\n' >assets/whitenoise-linux.metainfo.xml
printf 'pubkey: fixture\n' >zapstore.yaml
printf 'Original checkout.\n' >README.md
git add .
git commit -qm 'Seed release fixture'
HEAD_BEFORE="$(git rev-parse HEAD)"
git clone -q --bare . "$WORK/origin.git"
git clone -q --bare . "$WORK/github.git"
git remote add origin "$WORK/origin.git"
git remote add github "$WORK/github.git"
printf 'Uncommitted caller changes.\n' >README.md

export WN_NOTES_CMD='printf "### Fixed\n\n- Release fixture.\n"'
export VISUAL=true SHELL=/bin/bash
export ZAPSTORE_SIGNER=bunker://release-fixture
# Stop at the real gh client's first request, after the local tag push.
export GH_HOST=127.0.0.1:1 GH_TOKEN=fixture GH_ENTERPRISE_TOKEN=fixture
export GH_CONFIG_DIR="$WORK/gh" GH_PROMPT_DISABLED=1 NO_PROXY=127.0.0.1
pr_refs() { git --git-dir="$WORK/origin.git" for-each-ref --format='%(refname:short)' refs/heads/pr/; }

scripts/release.sh --dry-run >"$WORK/dry-run.log" 2>&1
[ -z "$(pr_refs)" ]
if scripts/release.sh --tag --tag-output >"$WORK/invalid.log" 2>&1; then
  echo 'Expected a missing tag-output path to be rejected.' >&2
  exit 1
fi
grep -F -- '--tag-output requires a file path.' "$WORK/invalid.log"
echo 'PASS: dry runs open no PR, and a missing output path is rejected.'

if printf 'n\n' | script -q -e -c scripts/release.sh /dev/null >"$WORK/cancel.log" 2>&1; then
  echo 'Expected cancellation to stop the release.' >&2
  exit 1
fi
grep -F 'Nothing was released.' "$WORK/cancel.log"
[ -z "$(pr_refs)" ]
echo 'PASS: cancellation opens no PR.'

printf 'y\n' | script -q -e -c scripts/release.sh /dev/null >"$WORK/release.log" 2>&1
PR="$(pr_refs)"
[[ "$PR" =~ ^pr/release-v[0-9]{4}\.[0-9]+\.[0-9]+-build\.[0-9]+$ ]]
RELEASE="$(git --git-dir="$WORK/origin.git" rev-parse "$PR")"
[ "$(git --git-dir="$WORK/origin.git" rev-parse master)" = "$HEAD_BEFORE" ]
[ "$(git --git-dir="$WORK/github.git" rev-parse master)" = "$HEAD_BEFORE" ]
git verify-commit "$RELEASE"
git log -1 --format=%b "$RELEASE" | grep -Fx '### Fixed'
[ "$(git rev-parse HEAD)" = "$HEAD_BEFORE" ]
[ "$(<README.md)" = 'Uncommitted caller changes.' ]
echo 'PASS: release opens a signed PR with the notes and leaves master alone.'

if scripts/publish.sh >"$WORK/early.log" 2>&1; then
  echo 'Expected publish to refuse an unmerged release.' >&2
  exit 1
fi
grep -F 'Merge the release PR first.' "$WORK/early.log"
[ -z "$(git --git-dir="$WORK/origin.git" tag -l)" ]
echo 'PASS: publish refuses to tag before the release PR is merged.'

# Merge the PR, then land another change, which must stay out of the tag.
git --git-dir="$WORK/origin.git" update-ref refs/heads/master "$RELEASE"
git clone -q "$WORK/origin.git" "$WORK/later"
git -C "$WORK/later" -c user.name=Later -c user.email=later@example.invalid \
  -c commit.gpgsign=false commit -q --allow-empty -m 'Merge a later change'
git -C "$WORK/later" push -q origin master

if scripts/publish.sh >"$WORK/publish.log" 2>&1; then
  echo 'Expected the unavailable local GitHub endpoint to stop publication.' >&2
  exit 1
fi
TAG="$(git --git-dir="$WORK/origin.git" tag -l 'v*-build.*')"
[ "pr/release-$TAG" = "$PR" ]
[ "$(git rev-parse "$TAG^{}")" = "$RELEASE" ]
[ "$(git --git-dir="$WORK/github.git" rev-parse "$TAG^{}")" = "$RELEASE" ]
[ "$(git --git-dir="$WORK/github.git" rev-parse master)" = "$HEAD_BEFORE" ]
git verify-tag "$TAG"
git tag -l --format='%(contents:body)' "$TAG" | grep -Fx '### Fixed'
[ "$(git rev-parse HEAD)" = "$HEAD_BEFORE" ]
[ "$(<README.md)" = 'Uncommitted caller changes.' ]
grep -F "Waiting for the GitHub release $TAG:" "$WORK/publish.log"
grep -F '127.0.0.1:1' "$WORK/publish.log"
! grep -Fq 'Downloading packages' "$WORK/publish.log"
echo 'PASS: publish tags the merged release commit, pushes only the tag, and waits for it.'
