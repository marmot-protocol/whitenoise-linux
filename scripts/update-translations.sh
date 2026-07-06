#!/usr/bin/env bash
# Extract @tr strings from Slint UI files and merge into locale catalogs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The gettext domain must match the crate that compiles the Slint UI
# (slint-build hardwires it to CARGO_PKG_NAME) — that is wnl-ui, not the app.
POT="$ROOT/lang/wnl-ui.pot"
DOMAIN="wnl-ui"

if ! command -v slint-tr-extractor >/dev/null 2>&1; then
    echo "slint-tr-extractor not found — install with: cargo install slint-tr-extractor" >&2
    exit 1
fi

mkdir -p lang/{en,it,de,ja}/LC_MESSAGES

find ui -name '*.slint' -print0 | sort -z | xargs -0 slint-tr-extractor -o "$POT"

# slint-tr-extractor rewrites the POT header with xgettext's placeholder
# values on every run; msgfmt -c (enforced by the pre-commit hook) warns on
# those, so pin the real values here. English is the source language, hence
# the Germanic plural rule. The revision date stays fixed to keep the output
# byte-stable (the same reason po-clean.sh drops POT-Creation-Date).
sed -i \
    -e 's/^"Project-Id-Version: PACKAGE VERSION\\n"$/"Project-Id-Version: wnl-ui\\n"/' \
    -e 's/^"PO-Revision-Date: YEAR-MO-DA HO:MI+ZONE\\n"$/"PO-Revision-Date: 2026-07-06 00:00+0000\\n"/' \
    -e 's/^"Last-Translator: FULL NAME <EMAIL@ADDRESS>\\n"$/"Last-Translator: Automatically generated\\n"/' \
    -e 's/^"Language-Team: LANGUAGE <LL@li.org>\\n"$/"Language-Team: none\\n"/' \
    -e 's/^"Language: \\n"$/"Language: en\\n"/' \
    -e 's/^"Plural-Forms: nplurals=1; plural=0;\\n"$/"Plural-Forms: nplurals=2; plural=(n != 1);\\n"/' \
    "$POT"

if ! command -v msgmerge >/dev/null 2>&1; then
    echo "msgmerge not found — install gettext (e.g. pacman -S gettext)" >&2
    exit 1
fi

for locale in it de ja; do
    PO="lang/$locale/LC_MESSAGES/$DOMAIN.po"
    if [[ ! -f "$PO" ]]; then
        msginit --no-translator --no-wrap --locale="$locale" --input="$POT" --output-file="$PO"
    else
        # --no-wrap so merged strings stay one-per-line and don't churn against
        # the po-clean normalization the commit filter/hook apply.
        msgmerge --no-wrap -U "$PO" "$POT"
    fi
done

# Finish by running the exact same normalization the po-clean filter/pre-commit
# hook apply (no-location, sort-output, no-wrap, drop POT-Creation-Date), so a
# fresh `update-translations.sh` produces byte-identical catalogs to a commit —
# no phantom diff between regenerating and staging.
for f in "$POT" lang/{it,de,ja}/LC_MESSAGES/"$DOMAIN".po; do
    tmp="$(mktemp)"
    scripts/po-clean.sh < "$f" > "$tmp" && mv "$tmp" "$f"
done

echo "Updated $POT and merged into it/de/ja catalogs (normalized via po-clean.sh)."
