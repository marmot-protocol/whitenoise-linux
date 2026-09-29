#!/usr/bin/env bash
# Generate a private build input; exclude the output from caches/source artifacts.
set +x
set -euo pipefail
export LC_ALL=C
umask 077

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/build/observability-tokens.toml"
mkdir -p "$HERE/build"
# Remove stale credentials even if the new input is rejected.
rm -f "$OUT"

metrics="${WN_METRICS_WRITE_TOKEN:-}"
audit="${WN_AUDIT_WRITE_TOKEN:-}"
# obs_parse accepts plain quoted values, not TOML escape sequences.
# Reject bytes requiring escapes, without echoing credentials in diagnostics.
for token in "$metrics" "$audit"; do
  case "$token" in
    *[![:print:]]*|*\"*|*\\*)
      echo 'Observability tokens require printable ASCII without double quotes or backslashes.' >&2
      exit 1
      ;;
  esac
done

# printf is a shell builtin: token values never enter a process argument list.
printf 'otlp_token = "%s"\ngoggles_token = "%s"\n' "$metrics" "$audit" > "$OUT"
