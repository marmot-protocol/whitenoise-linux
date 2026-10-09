#!/usr/bin/env bash
set -euo pipefail
MDK="$1"
shift
MDK_PATCHES=("$@")

# Compare whole prefixes: later patches can alter earlier reverse-check context.
mdk_applied_prefix() (
  index="$(mktemp "$MDK/.wn-index.XXXXXX")"
  trap 'rm -f "$index"' EXIT
  export GIT_INDEX_FILE="$index"
  git -C "$MDK" read-tree HEAD || return 1
  for patch in "${MDK_PATCHES[@]}"; do
    git -C "$MDK" apply --cached "$patch" || return 1
  done

  remaining="${#MDK_PATCHES[@]}"
  while ! git -C "$MDK" diff --quiet --no-ext-diff; do
    if [ "$remaining" -eq 0 ]; then
      return 1
    fi
    remaining=$((remaining - 1))
    git -C "$MDK" apply --cached --reverse "${MDK_PATCHES[remaining]}" || return 1
  done
  printf '%s\n' "$remaining"
)

applied="$(mdk_applied_prefix)" || applied=0
for patch in "${MDK_PATCHES[@]:applied}"; do
  if git -C "$MDK" apply --check "$patch" 2>/dev/null; then
    git -C "$MDK" apply "$patch"
  elif ! git -C "$MDK" apply --reverse --check "$patch" 2>/dev/null; then
    echo "==> MDK patch conflicts with vendor/mdk: $patch" >&2
    exit 1
  fi
done
