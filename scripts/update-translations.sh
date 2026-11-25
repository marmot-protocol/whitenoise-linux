#!/usr/bin/env bash
# Extract translatable strings from the Odin UI and merge them into the
# locale catalogs in lang/. The extracted template is a temp file: only the
# catalogs are tracked, so a feature branch that adds a string touches no
# file under lang/, and a translation pass is a branch of its own.
#
# Extraction is plain xgettext in C mode: Odin's string, comment and call
# syntax is close enough to C that the C lexer reads it correctly, once
# backtick raw strings are neutralized (the C lexer has no such literal and
# desyncs on the stray quotes inside one). Nothing is written back to the
# copies, so the neutralized sources live in a temp dir and are thrown away.
#
# Two markers are extracted, and nothing else:
#
#   tr("...")          the string is translated where it is written
#   N_("...")          the string is held in a package-level table or
#                      returned from a copy proc; some tr(var) further down
#                      translates it (see i18n.odin)
#
# UI helpers take display strings and never call tr() on a parameter, so
# every msgid is marked where it is written.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/app"
LOCALES=(it de ja ko)

for tool in xgettext msgmerge; do
    command -v "$tool" >/dev/null || { echo "✗ $tool not found — install gettext." >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
POT="$TMP/wnl-ui.pot"

# `...` raw strings hold regex/quote fragments the C lexer would read as an
# unterminated string literal, silently dropping every msgid after it in
# that file. They are never msgids themselves, so blank them out.
for f in "$SRC"/*.odin; do
    sed 's/`[^`]*`/""/g' "$f" > "$TMP/$(basename "$f")"
done

# Run from the temp dir so the `#:` references come out as bare filenames.
# They do not survive the commit either way: scripts/po-clean.sh strips
# locations, so a source-line shift never shows up as a catalog diff.
(cd "$TMP" && xgettext -L C --from-code=UTF-8 --no-wrap --sort-by-file \
    --keyword=tr --keyword=N_ --package-name=wnl-ui --copyright-holder="" --msgid-bugs-address="" \
    -o wnl-ui.pot ./*.odin) 2>&1 | grep -vE 'msgid-bugs-address|Makevars|MSGID_BUGS|Empty msgid|^ +(gettext|meta information)' || true

for loc in "${LOCALES[@]}"; do
    po="$ROOT/lang/$loc/LC_MESSAGES/wnl-ui.po"
    msgmerge --quiet --no-wrap --backup=off --update "$po" "$POT"
    printf '%-4s %s\n' "$loc" "$(msgfmt --statistics -o /dev/null "$po" 2>&1)"
done

echo "==> $(grep -c '^msgid "..*"' "$POT") source strings"
