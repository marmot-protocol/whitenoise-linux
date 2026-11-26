#!/usr/bin/env bash
# Shared by packaging and release checks; the app embeds this same literal.
# Pass a release tag to also check that it matches the source version.
set -euo pipefail

version_error() { echo "$*" >&2; exit 1; }

check_calendar() {
  local year=$((10#$1)) month=$((10#$2)) day=$((10#$3))
  local month_days=(31 28 31 30 31 30 31 31 30 31 30 31)
  if ((year % 4 == 0 && (year % 100 != 0 || year % 400 == 0))); then month_days[1]=29; fi
  if ((day > month_days[month - 1])); then
    version_error "Invalid date: $year-$month has no day $day"
  fi
}

parse_version() {
  local value=$1
  if [[ ! "$value" =~ ^([0-9]{4})\.([1-9]|1[0-2])\.([1-9]|[12][0-9]|3[01])\+([1-9][0-9]*)$ ]]; then
    version_error "Invalid app version: expected YYYY.M.D+REVISION, got '$value'"
  fi
  check_calendar "${BASH_REMATCH[@]:1:3}"
  printf '%s %s-%02d-%02d\n' "$value" "${BASH_REMATCH[@]:1:3}"
}

case "${1:-}" in
  --tag)
    [[ $# == 2 && "$2" == v*-build.* ]] || version_error 'Expected a release tag'
    value=${2#v}
    parse_version "${value/-build./+}"
    ;;
  --date)
    [[ $# == 2 && "$2" =~ ^([0-9]{4})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]] ||
      version_error 'Expected a UTC date in YYYY-MM-DD format'
    check_calendar "${BASH_REMATCH[@]:1:3}"
    printf '%s.%d.%d\n' "${BASH_REMATCH[1]}" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))"
    ;;
  *)
    tree=${WN_VERSION_ROOT:-$(dirname "$0")/..}
    version=$(sed -n 's/^APP_VERSION :: "\([^"]*\)".*/\1/p' "$tree/app/advanced.odin")
    parse_version "$version" >/dev/null
    if [[ $# -gt 0 && "$1" != "v${version/+/-build.}" ]]; then
      version_error "Release tag must be v${version/+/-build.}, got '$1'"
    fi
    printf '%s\n' "$version"
    ;;
esac
