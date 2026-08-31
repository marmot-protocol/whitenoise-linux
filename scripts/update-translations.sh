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
# Three shapes of translatable string are extracted:
#
#   tr("…")            the string is translated where it is written
#   N_("…")            the string is held in a package-level table or
#                      returned from a copy proc; some tr(var) further down
#                      translates it (see i18n.odin)
#   helper("…", …)     the helper's own body calls tr() on that parameter,
#                      so the literal at the call site is the msgid. Each
#                      one is listed below as name:argument-position.
#
# Adding a helper that tr()s a parameter means adding it to HELPERS, or its
# call sites go unextracted and fall back to English.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/app"
POT="$ROOT/lang/wnl-ui.pot"
LOCALES=(it de ja)

for tool in xgettext msgmerge; do
    command -v "$tool" >/dev/null || { echo "✗ $tool not found — install gettext." >&2; exit 1; }
done

# procedure:argument-position for every proc that calls tr() on a parameter.
# A proc that translates two of its parameters is listed once per position and
# split across passes below: `name:1,2` would mean ngettext singular/plural to
# xgettext, not "extract both".
HELPERS=(
    section_head:2 login_button:2 kp_kv:3 ctx_item:3
    centered_note:2 centered_note:3 eyebrow:1 profile_rail_link:3 micro_button:2 form_row:3
    row_labels:1 row_labels:2 settings_header:2 settings_header:3
    copy_text:3 tooltip:1
)

# One pass per keyword group, where a group holds at most one position per
# proc; the passes are then merged with the first occurrence winning.
declare -A seen=()
PASS1=(--keyword=tr --keyword=N_) PASS2=()
for h in "${HELPERS[@]}"; do
    name="${h%%:*}"
    if [ -n "${seen[$name]:-}" ]; then PASS2+=("--keyword=$h"); else PASS1+=("--keyword=$h"); fi
    seen[$name]=1
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
extract() { # <output> <keyword…>
    local out="$1"; shift
    (cd "$TMP" && xgettext -L C --from-code=UTF-8 --no-wrap --sort-by-file \
        "$@" --package-name=wnl-ui --copyright-holder="" --msgid-bugs-address="" \
        -o "$out" ./*.odin) 2>&1 | grep -vE 'msgid-bugs-address|Makevars|MSGID_BUGS|Empty msgid|^ +(gettext|meta information)' || true
}
extract pass1.pot "${PASS1[@]}"
extract pass2.pot "${PASS2[@]}"
msgcat --use-first --no-wrap -o "$TMP/wnl-ui.pot" "$TMP/pass1.pot" "$TMP/pass2.pot"
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
