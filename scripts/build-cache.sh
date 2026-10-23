#!/usr/bin/env bash
# Content keys and output manifests shared by native and cross build stages.
# GNU coreutils are installed on every build host, including macos-setup.sh.
build_cache_key() (
  set -o pipefail
  local identity="$1" path real item dir hash=sha256sum sort=sort stat=stat resolve=realpath
  shift
  command -v gsha256sum >/dev/null 2>&1 && hash=gsha256sum
  command -v gsort >/dev/null 2>&1 && sort=gsort
  command -v gstat >/dev/null 2>&1 && stat=gstat
  command -v grealpath >/dev/null 2>&1 && resolve=grealpath
  dir="$(mktemp -d)" || return
  trap 'rm -rf "$dir"' EXIT
  : >"$dir/paths"
  for path in "$@"; do
    case "/$path/" in */.git/* | */.hg/* | */.svn/* | */.env/* | *.env/*) continue ;; esac
    if [ ! -e "$path" ]; then
      echo "Missing cache input: $path" >&2
      return 1
    fi
    # find reports directory symlink cycles as errors, never partial keys.
    find -L "$path" \( -name .git -o -name .hg -o -name .svn -o -name .env -o -name '*.env' \) -prune -o -print0 >>"$dir/paths" || return
  done
  LC_ALL=C "$sort" -zu "$dir/paths" >"$dir/sorted" || return
  # Resolve in batches rather than launching one process per SDK header.
  : >"$dir/resolved"
  if [ -s "$dir/sorted" ]; then
    xargs -0 "$resolve" -e -z -- <"$dir/sorted" >"$dir/resolved" || return
  fi
  : >"$dir/safe"
  : >"$dir/files"
  : >"$dir/names"
  while IFS= read -r -d '' item && IFS= read -r -d '' real <&3; do
    case "/$real/" in */.git/* | */.hg/* | */.svn/* | */.env/* | *.env/*) continue ;; esac
    if [ ! -f "$item" ] && [ ! -d "$item" ]; then
      echo "Unsupported cache input: $item" >&2
      return 1
    fi
    printf '%s\0' "$item" >>"$dir/safe"
    printf '%s\0%s\0' "$item" "$real" >>"$dir/names"
    if [ -f "$item" ]; then printf '%s\0' "$item" >>"$dir/files"; fi
  done <"$dir/sorted" 3<"$dir/resolved"
  # Names, target names, modes and contents matter; mtimes/ownership do not.
  # No .env is ever opened, including an innocently named link to one.
  {
    printf 'wn-cache-v3\0%s\0' "$identity"
    if [ -s "$dir/safe" ]; then
      xargs -0 "$stat" -L --printf='%n\000%f\000' -- <"$dir/safe" || exit 1
      # Non-dereferenced %N includes raw link text (relative vs absolute).
      LC_ALL=C QUOTING_STYLE=shell-escape-always xargs -0 "$stat" --printf='%n\000%f\000%N\000' -- <"$dir/safe" || exit 1
      cat "$dir/names" || exit 1
    fi
    if [ -s "$dir/files" ]; then
      xargs -0 "$hash" --zero -- <"$dir/files" || exit 1
    fi
  } | "$hash" | cut -d' ' -f1
)
build_cache_manifest() (
  local dir path item real resolve=realpath
  command -v grealpath >/dev/null 2>&1 && resolve=grealpath
  dir="$(mktemp -d)" || return
  trap 'rm -rf "$dir"' EXIT
  : >"$dir/paths"
  for path in "$@"; do
    [ -e "$path" ] || return 1
    # Outputs cannot silently omit secrets that an archiver would include.
    # This walk and canonicalization inspect names only, never file bytes.
    find -L "$path" -print0 >>"$dir/paths" || return
  done
  : >"$dir/resolved"
  if [ -s "$dir/paths" ]; then
    xargs -0 "$resolve" -e -z -- <"$dir/paths" >"$dir/resolved" || return
  fi
  while IFS= read -r -d '' item && IFS= read -r -d '' real <&3; do
    case "/$item/ /$real/" in
    */.git/* | */.hg/* | */.svn/* | */.env/* | *.env/*)
      echo "Excluded node in cache outputs: $item" >&2
      return 1
      ;;
    esac
  done <"$dir/paths" 3<"$dir/resolved"
  build_cache_key outputs "$@"
)
build_cache_fresh() {
  local key="$1" stamp="$2" manifest saved
  shift 2
  [ -f "$stamp" ] && [ "$#" -gt 0 ] || return 1
  IFS= read -r saved <"$stamp" || return 1
  [ "$saved" = "$key" ] || return 1
  manifest="$(build_cache_manifest "$@")" || return 1
  [ "$(cat "$stamp")" = "$(printf '%s\n%s' "$key" "$manifest")" ]
}
build_cache_store() {
  local key="$1" stamp="$2" manifest tmp
  shift 2
  [ "$#" -gt 0 ] || return 1
  manifest="$(build_cache_manifest "$@")" || return
  mkdir -p "$(dirname "$stamp")" || return
  tmp="$(mktemp "$stamp.XXXXXX")" || return
  if ! printf '%s\n%s\n' "$key" "$manifest" >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$stamp"
}
