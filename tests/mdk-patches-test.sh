#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
git init -q "$fixture/mdk"
cd "$fixture/mdk"
target='patch [target].txt'
source='marmot-c/src/lib.rs'
mkdir -p "$(dirname "$source")"
printf 'base\ncontext\nend\n' >"$target"
printf 'pub const SOURCE_SENTINEL: &str = "baseline";\n' >"$source"
git --literal-pathspecs add "$target" "$source"
git -c user.name=Fixture -c user.email=fixture@example.invalid commit -S -qm 'Add patch staging fixtures'
base="$(git write-tree)"
patches=()
for content in $'one\ncontext\nend' $'one\nchanged\nend' $'three\nchanged\nend'; do
  patch="$fixture/${#patches[@]}.patch"
  printf '%s\n' "$content" >"$target"
  git diff --no-ext-diff --binary >"$patch"
  git --literal-pathspecs add "$target"
  patches+=("$patch")
done
cp "$target" "$fixture/expected"
git --literal-pathspecs restore --source=HEAD --staged --worktree -- "$target"

# Fresh staging and rerunning the complete series preserve the real index.
bash "$HERE/scripts/apply-mdk-patches.sh" "$PWD" "${patches[@]}"
cmp "$fixture/expected" "$target"
test "$(git write-tree)" = "$base"
bash "$HERE/scripts/apply-mdk-patches.sh" "$PWD" "${patches[@]}"
cmp "$fixture/expected" "$target"

# A complete overlapping stack still matches with unrelated runtime source edits.
printf 'pub const SOURCE_SENTINEL: &str = "edited";\n' >"$source"
cp "$source" "$fixture/source-edited"
bash "$HERE/scripts/apply-mdk-patches.sh" "$PWD" "${patches[@]}"
cmp "$fixture/expected" "$target"
cmp "$fixture/source-edited" "$source"
test "$(git write-tree)" = "$base"

# An appended patch overlaps the first patch's reverse-check context.
git --literal-pathspecs restore --source=HEAD --worktree -- "$target"
bash "$HERE/scripts/apply-mdk-patches.sh" "$PWD" "${patches[@]:0:2}"
if git apply --reverse --check "${patches[0]}" 2>/dev/null; then
  echo 'Fixture lacks overlapping reverse-check context.' >&2
  exit 1
fi
bash "$HERE/scripts/apply-mdk-patches.sh" "$PWD" "${patches[@]}"
cmp "$fixture/expected" "$target"
cmp "$fixture/source-edited" "$source"
test "$(git write-tree)" = "$base"

# Conflicting local edits fail without changing the worktree or index.
printf 'local\nchanged\nend\n' >"$target"
cp "$target" "$fixture/local"
if bash "$HERE/scripts/apply-mdk-patches.sh" "$PWD" "${patches[@]}"; then
  echo 'Accepted conflicting local edits.' >&2
  exit 1
fi
cmp "$fixture/local" "$target"
cmp "$fixture/source-edited" "$source"
test "$(git write-tree)" = "$base"
echo 'MDK patch staging checks passed.'
