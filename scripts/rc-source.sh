#!/usr/bin/env bash
# Source helpers for the signer and verifier. Never source code from the candidate tree.

rc_die() { echo "$*" >&2; exit 1; }

rc_gpg_cleanup() {
  gpgconf --homedir "$1" --kill gpg-agent
  rm -rf "$1"
}

rc_fingerprint() {
  gpg --batch --with-colons --show-keys "$1" |
    awk -F: '$1 == "pub" { primary++; next_fpr = 1 }
      $1 == "fpr" && next_fpr { fp = $10; next_fpr = 0 }
      END { if (primary != 1 || length(fp) != 40) exit 1; print fp }'
}

rc_signed_by() {
  local kind=$1 oid=$2 primary=$3 status
  status=$(git -c gpg.format=openpgp -c gpg.program=gpg -c gpg.openpgp.program=gpg \
    "verify-$kind" --raw "$oid" 2>&1) || return
  awk -v key="$primary" '
    $1 == "[GNUPG:]" && $2 == "VALIDSIG" && $NF == key { valid++ }
    $1 == "[GNUPG:]" && $2 ~ /^(BADSIG|ERRSIG|EXPSIG|EXPKEYSIG|REVKEYSIG)$/ { bad = 1 }
    END { exit !(valid == 1 && !bad) }
  ' <<< "$status"
}

rc_edit() {
  local path=$1 version=$2 date=$3
  case "$path" in
    app/advanced.odin)
      sed "s/^APP_VERSION :: \"[^\"]*\"/APP_VERSION :: \"$version\"/"
      ;;
    assets/whitenoise-linux.metainfo.xml)
      sed "s|^  <releases>\$|&\n    <release version=\"$version\" date=\"$date\"/>|"
      ;;
    *) rc_die "Not a stamp path: $path" ;;
  esac
}

rc_reservation() {
  local canary=$1 tags tag kind subject parents msg
  tags=$(git for-each-ref --format='%(refname:strip=2) %(objecttype) %(contents:subject)' refs/tags) || return
  while read -r tag kind subject; do
    [[ "$kind" == tag ]] || continue
    msg=$(git for-each-ref --format='%(contents:trailers:key=Canary-SHA,valueonly)' "refs/tags/$tag") || return
    [[ "$subject" == 'White Noise RC' || -n "$msg" ]] || continue
    parents=$(git show -s --format=%P "refs/tags/$tag^{}" 2>/dev/null) || parents=
    if [[ " $parents " == *" $canary "* ]] || grep -Fxq "$canary" <<< "$msg"; then
      printf '%s\n' "$tag"
    fi
  done <<< "$tags"
}
