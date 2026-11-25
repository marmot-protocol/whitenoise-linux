#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'gpgconf --kill gpg-agent; rm -rf "$tmp"' EXIT
export GNUPGHOME="$tmp/gnupg" GITHUB_OUTPUT="$tmp/output"
mkdir -m 700 "$GNUPGHOME"
mkdir -p "$tmp/base/scripts" "$tmp/base/packaging/ci"
cp "$root/scripts/pr-gate.sh" "$tmp/base/scripts/"
gpg --batch --passphrase '' --quick-generate-key 'Team <team@example.test>' ed25519 sign 0
gpg --batch --passphrase '' --quick-generate-key 'Outside <outside@example.test>' ed25519 sign 0
gpg --batch --armor --export team@example.test > "$tmp/base/packaging/ci/team-signers.asc"

git init -q -b master "$tmp/repo"
cd "$tmp/repo"
git config user.name Fixture
git config user.email fixture@example.test
git config gpg.format openpgp
git -c commit.gpgsign=false commit -qm Base --allow-empty
base=$(git rev-parse HEAD)
checks='Local-Checks: build and tests'
review='Local-Review: independent code review'

signed() {
  local signer=$1
  shift
  git -c core.hooksPath=/dev/null commit -q --allow-empty -S"$signer@example.test" -m Change "$@"
}

expect_lane() {
  local expected=$1
  : > "$GITHUB_OUTPUT"
  bash "$tmp/base/scripts/pr-gate.sh" "$base" "$(git rev-parse HEAD)"
  [[ $(cat "$GITHUB_OUTPUT") == "lane=$expected" ]]
}

expect_failure() {
  : > "$GITHUB_OUTPUT"
  if bash "$tmp/base/scripts/pr-gate.sh" "$base" "$(git rev-parse HEAD)"; then
    echo 'Trusted commit without unique evidence was accepted' >&2
    exit 1
  fi
  [[ ! -s "$GITHUB_OUTPUT" ]]
}

expect_lane build
signed team -m "$checks"$'\n'"$review"
expect_lane static
signed team
expect_failure
signed outside
expect_lane build

git switch -q --detach "$base"
signed team -m "$checks"$'\n'"$review"$'\nLocal-Review: duplicate'
expect_failure

git switch -q --detach "$base"
git -c commit.gpgsign=false commit -qm Unsigned --allow-empty
expect_lane build

git switch -q --detach "$base"
mkdir -p packaging/ci
printf 'change\n' > packaging/ci/team-signers.asc
git add packaging/ci/team-signers.asc
signed team -m "$checks"$'\n'"$review"
expect_lane build

git switch -q --detach "$base"
signed team -m "$checks"$'\n'"$review"
git clone -q --depth 1 "file://$tmp/repo" "$tmp/shallow"
(cd "$tmp/shallow"; expect_lane build)
printf 'PR gate fixtures passed\n'
