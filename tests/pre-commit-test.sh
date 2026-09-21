#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/scripts"
cp "$HERE/scripts/vet-imports.sh" "$fixture/scripts/"
cd "$fixture"
git init -q
git config core.hooksPath /dev/null
git config commit.gpgsign false
git config user.name Test
git config user.email test@example.invalid

# Spaces in paths, automatic formatting, and the staged blob all agree.
printf 'package main\nvalue::42\n' > 'with space.odin'
odinfmt "$fixture/with space.odin" > expected
git add -- 'with space.odin'
bash "$HERE/.githooks/pre-commit"
cmp expected 'with space.odin'
git show ':with space.odin' > staged
cmp expected staged
git commit -qm Initial

# Partial staging must fail without altering either version.
printf '\nother::1\n' >> 'with space.odin'
git add -- 'with space.odin'
printf '\nunstaged::2\n' >> 'with space.odin'
cp 'with space.odin' working
git show ':with space.odin' > staged
if bash "$HERE/.githooks/pre-commit"; then
  echo 'Hook accepted unstaged Odin edits.' >&2
  exit 1
fi
cmp working 'with space.odin'
git show ':with space.odin' > after
cmp staged after

# Deleted files are never passed to the formatter.
git rm -fq -- 'with space.odin'
bash "$HERE/.githooks/pre-commit"
echo 'Pre-commit formatting checks passed.'
