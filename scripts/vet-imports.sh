#!/usr/bin/env bash
# Odin does not warn on an unused import, so copy-pasted import headers
# accumulate. This is the check; callers decide the severity: a warning
# locally (build.sh, dev.sh, the pre-commit hook), fatal in CI.
#
# Exits 1 when app/ has an unused import (or any other check error), 0 when
# clean or when the toolchain/vendored packages are not there yet.
set -uo pipefail
cd "$(dirname "$0")/.."

command -v odin >/dev/null 2>&1 || exit 0
[ -d vendor/clay ] || exit 0

out="$(odin check app -vet-unused-imports -max-error-count:5000 2>&1)" && exit 0
printf '%s\n' "$out" >&2
exit 1
