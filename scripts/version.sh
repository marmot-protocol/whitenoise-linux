#!/usr/bin/env bash
# Shared by packaging and release checks; the app embeds this same literal.
# Pass a release tag to also check that it matches the source version.
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(sed -n 's/^APP_VERSION :: "\([^"]*\)".*/\1/p' app/advanced.odin)"
if [[ ! "$version" =~ ^([0-9]{4})\.([1-9]|1[0-2])\.([1-9]|[12][0-9]|3[01])\+([1-9][0-9]*)$ ]]; then
  echo "Invalid app version: expected YYYY.M.D+REVISION, got '$version'" >&2
  exit 1
fi
# The regex bounds day by 31; reject days past the month's end (Feb 30).
# Plain bash: BSD date has no -d.
year=$((10#${BASH_REMATCH[1]})) month=$((10#${BASH_REMATCH[2]})) day=$((10#${BASH_REMATCH[3]}))
month_days=(31 28 31 30 31 30 31 31 30 31 30 31)
if ((year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))); then month_days[1]=29; fi
if ((day > month_days[month - 1])); then
  echo "Invalid app version: $year-$month has no day $day" >&2
  exit 1
fi
if [ "$#" -gt 0 ] && [ "$1" != "v${version/+/-build.}" ]; then
  echo "Release tag must be v${version/+/-build.}, got '$1'" >&2
  exit 1
fi
printf '%s\n' "$version"
