#!/usr/bin/env bash
# Cut a release, date-versioned:
#
#   1. APP_VERSION becomes today's date plus the next revision
#      (2026.9.27+1, then +2 the same day, +1 again on a new date; Velopack
#      orders by the date first). The tag is v2026.9.27-build.1.
#   2. A small model drafts release notes from the commits since the last
#      tag. WN_NOTES_CMD replaces it: any command reading the prompt on
#      stdin and printing notes (default: claude -p --model haiku).
#   3. The notes open in $VISUAL/$EDITOR (vim by default) for editing, then
#      you confirm. Nothing is committed, tagged or pushed before that.
#   4. The version bump is committed, the tag is created with the notes as
#      its message, and master plus the tag are pushed to both remotes.
#
# The tag reaching `github` starts .github/workflows/release.yml. It builds
# every package and then creates the GitHub release, titled from the tag's
# first line with the notes as its body. It refuses a tag that does not
# match APP_VERSION (scripts/version.sh).
#
# Usage: scripts/release.sh [--dry-run]   (dry run: print the plan and draft)
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) echo "Usage: scripts/release.sh [--dry-run]" >&2; exit 2 ;;
esac
REMOTES=(origin github)
NOTES_CMD="${WN_NOTES_CMD:-claude -p --model haiku}"
EDITOR_CMD="${VISUAL:-${EDITOR:-vim}}"

# Release only a clean, current master: the tag must name what CI builds.
if [ "$(git branch --show-current)" != master ]; then
  echo "Releases are cut from master." >&2
  exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Commit or stash your changes first." >&2
  exit 1
fi
if [ -z "$DRY_RUN" ] && [ ! -t 0 ]; then
  echo "Run this from a terminal: the notes open in your editor." >&2
  exit 1
fi
for remote in "${REMOTES[@]}"; do
  git fetch -q --tags "$remote" master
  if ! git merge-base --is-ancestor "$remote/master" HEAD; then
    echo "master is behind $remote/master; pull first." >&2
    exit 1
  fi
done

current="$(bash scripts/version.sh)"
today="$(date +%Y).$((10#$(date +%m))).$((10#$(date +%d)))"
revision=1
if [ "${current%+*}" = "$today" ]; then revision=$((${current#*+} + 1)); fi
version="$today+$revision"
tag="v$today-build.$revision"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "Tag $tag already exists." >&2
  exit 1
fi

# The commits since the previous release; the first release has no tag to
# start from, so it looks at the most recent 50.
previous="$(git tag -l 'v*-build.*' --sort=-creatordate | head -n 1)"
if [ -n "$previous" ]; then
  commits="$(git log --no-merges --format='- %s%n%w(0,2,2)%b' "$previous..HEAD")"
  since="since $previous"
else
  commits="$(git log --no-merges --format='- %s%n%w(0,2,2)%b' -n 50)"
  since="(first release: last 50 commits)"
fi
if [ -z "$commits" ]; then
  echo "Nothing to release $since." >&2
  exit 1
fi
echo "Release $tag: APP_VERSION $current -> $version, commits $since, push to ${REMOTES[*]}"

notes="$(mktemp)"
trap 'rm -f "$notes"' EXIT
echo "Drafting release notes with: $NOTES_CMD"
if ! {
  cat <<'PROMPT'
Write release notes for White Noise, a desktop client for private group messaging (Marmot: MLS over Nostr). Input: the git commits since the last release.

Rules:
- Markdown. Short "### " headings only for groups that have entries, from: New, Improved, Fixed, Platforms and packaging.
- One bullet per user-visible change, in plain words a user understands. Merge related commits. Drop commits that only touch CI, tests, refactors or internal tooling unless they change what users download or run.
- Address the reader as "you". No marketing, superlatives, exclamation points or em dashes. No introduction or closing line.
- Output only the notes.

Commits:
PROMPT
  printf '%s\n' "$commits"
} | sh -c "$NOTES_CMD" >"$notes" || ! grep -q '[^[:space:]]' "$notes"; then
  # Keep going with the raw commit list rather than stopping the release.
  echo "The notes model failed; starting from the commit list instead." >&2
  printf '%s\n' "$commits" >"$notes"
fi

if [ -n "$DRY_RUN" ]; then
  echo
  cat "$notes"
  exit 0
fi

echo "Opening the draft in $EDITOR_CMD. Save the notes you want published."
sh -c "$EDITOR_CMD \"\$1\"" editor "$notes"
if ! grep -q '[^[:space:]]' "$notes"; then
  echo "Empty notes; nothing was released." >&2
  exit 1
fi
echo
cat "$notes"
echo
read -r -p "Tag $tag with these notes and push to ${REMOTES[*]}? [y/N] " answer
case "$answer" in
  y | Y | yes) ;;
  *) echo "Nothing was released." >&2; exit 1 ;;
esac

sed "s/^APP_VERSION :: \"[^\"]*\"/APP_VERSION :: \"$version\"/" app/advanced.odin >app/advanced.odin.tmp
mv app/advanced.odin.tmp app/advanced.odin
bash scripts/version.sh "$tag" >/dev/null
git commit -q -m "Release $version" app/advanced.odin
# verbatim: the default cleanup strips lines starting with "#", which would
# drop the Markdown headings.
{ printf 'White Noise %s\n\n' "$version"; cat "$notes"; } | git tag -a "$tag" --cleanup=verbatim -F -
for remote in "${REMOTES[@]}"; do
  git push "$remote" master "$tag"
done
echo "Pushed $tag. GitHub builds every package, then publishes the release:"
echo "https://github.com/marmot-protocol/whitenoise-linux/actions"
