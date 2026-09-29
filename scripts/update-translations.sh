#!/usr/bin/env bash
# Extract translatable strings from the Odin UI and merge them into the
# locale catalogs in lang/.
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
POT="$ROOT/lang/wnl-ui.pot"
LOCALES=(it de ja)

for tool in xgettext msgmerge; do
    command -v "$tool" >/dev/null || { echo "✗ $tool not found — install gettext." >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

# Fill the header fields xgettext leaves as placeholders. msgfmt --check warns
# on every one of them, and the pre-commit hook treats those warnings as
# fatal. The revision date is a constant so the header never churns.
sed -i \
    -e 's|^"PO-Revision-Date: .*|"PO-Revision-Date: 2026-07-06 00:00+0000\\n"|' \
    -e 's|^"Last-Translator: .*|"Last-Translator: Automatically generated\\n"|' \
    -e 's|^"Language-Team: .*|"Language-Team: none\\n"|' \
    -e 's|^"Language: .*|"Language: en\\n"|' \
    "$TMP/wnl-ui.pot"
# Drop xgettext's placeholder title block and the `#, fuzzy` it marks the
# header with, so the file opens on the header entry like the old catalogs.
sed -i '1,5{/^# SOME DESCRIPTIVE TITLE\.$/d; /^# This file is put in the public domain\.$/d; /^# FIRST AUTHOR <EMAIL@ADDRESS>, YEAR\.$/d; /^#, fuzzy$/d}' "$TMP/wnl-ui.pot"
mv "$TMP/wnl-ui.pot" "$POT"

for loc in "${LOCALES[@]}"; do
    po="$ROOT/lang/$loc/LC_MESSAGES/wnl-ui.po"
    msgmerge --quiet --no-wrap --backup=off --update "$po" "$POT"
    printf '%-4s %s\n' "$loc" "$(msgfmt --statistics -o /dev/null "$po" 2>&1)"
done

echo "==> $POT ($(grep -c '^msgid ' "$POT") entries)"
