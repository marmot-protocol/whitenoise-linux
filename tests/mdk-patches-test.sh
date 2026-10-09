#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
# Reuse the existing commit rather than requiring signing keys for a fixture.
git clone -q --shared "$HERE" "$fixture/mdk"
cd "$fixture/mdk"
base="$(git write-tree)"
patches=()
for content in $'one\ncontext\nend' $'one\nchanged\nend' $'three\nchanged\nend'; do
  patch="$fixture/${#patches[@]}.patch"
  printf '%s\n' "$content" > DEPS_PIN
  git diff --no-ext-diff --binary > "$patch"
  git add DEPS_PIN
  patches+=("$patch")
done
cp DEPS_PIN "$fixture/expected"
git restore --source=HEAD --staged --worktree DEPS_PIN

# Fresh staging and rerunning the complete series preserve the real index.
bash "$HERE/scripts/apply-mdk-patches.sh" "$PWD" "${patches[@]}"
cmp "$fixture/expected" DEPS_PIN
test "$(git write-tree)" = "$base"
bash "$HERE/scripts/apply-mdk-patches.sh" "$PWD" "${patches[@]}"
cmp "$fixture/expected" DEPS_PIN

# An appended patch overlaps the first patch's reverse-check context.
git restore --source=HEAD --worktree DEPS_PIN
bash "$HERE/scripts/apply-mdk-patches.sh" "$PWD" "${patches[@]:0:2}"
if git apply --reverse --check "${patches[0]}" 2>/dev/null; then
  echo 'Fixture lacks overlapping reverse-check context.' >&2
  exit 1
fi
bash "$HERE/scripts/apply-mdk-patches.sh" "$PWD" "${patches[@]}"
cmp "$fixture/expected" DEPS_PIN
test "$(git write-tree)" = "$base"

# Conflicting local edits fail without changing the worktree or index.
printf 'local\nchanged\nend\n' > DEPS_PIN
cp DEPS_PIN "$fixture/local"
if bash "$HERE/scripts/apply-mdk-patches.sh" "$PWD" "${patches[@]}"; then
  echo 'Accepted conflicting local edits.' >&2
  exit 1
fi
cmp "$fixture/local" DEPS_PIN
test "$(git write-tree)" = "$base"
echo 'MDK patch staging checks passed.'
