#!/usr/bin/env bash
# Import portable signing-key backups, then read them back before reporting success.
set +ax
set -euo pipefail
umask 077

if [[ "${1:-}" == --help || $# -lt 2 ]]; then
  printf 'Usage: %s DATABASE.kdbx KEY_BACKUP_DIR [KEEPASSXC_UNLOCK_OPTIONS...]\n' "$0"
  printf 'Close the database in KeePassXC first. Source keys are never deleted.\n'
  printf 'Unlock options include -k KEYFILE, --no-password, and -y SLOT[:SERIAL].\n'
  [[ "${1:-}" == --help ]] && exit 0
  exit 2
fi
HERE="$(cd "$(dirname "$0")/.." && pwd)"
database="$(realpath -- "$1")"
keys="$(realpath -- "$2")"
shift 2
unlock_options=("$@")
entry='/White Noise release signing keys'
if [[ -e "$database.lock" ]]; then
  printf 'Close the database in KeePassXC before importing: %s\n' "$database" >&2
  exit 1
fi
for source in "$keys/sparkle-seed.base64" "$keys/sparkle-private.pem"; do
  if [[ ! -s "$source" ]]; then
    printf 'Missing or empty key backup: %s\n' "$source" >&2
    exit 1
  fi
done
if [[ ! -d "$keys/gnupg" ]]; then
  printf 'Missing GnuPG key backup: %s/gnupg\n' "$keys" >&2
  exit 1
fi
if ! command -v gpg >/dev/null; then
  printf 'Install GnuPG before importing release keys.\n' >&2
  exit 1
fi
work="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/wn-key-import.XXXXXX")"
cleanup() {
  rm -rf -- "$work"
  unset database_password
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if command -v keepassxc-cli >/dev/null; then
  cli=(keepassxc-cli)
elif command -v flatpak >/dev/null && flatpak info org.keepassxc.KeePassXC >/dev/null 2>&1; then
  cli=(flatpak run --no-documents-portal --command=keepassxc-cli
    --nosocket=x11 --nosocket=fallback-x11 --nosocket=wayland
    --filesystem="$work" --filesystem="$(dirname "$database")" org.keepassxc.KeePassXC)
else
  printf 'Install KeePassXC, either natively or as org.keepassxc.KeePassXC.\n' >&2
  exit 1
fi

# Keep the password on stdin, not in process arguments or exported variables.
unset database_password
password_mode=Prompt
for ((i = 0; i < ${#unlock_options[@]}; i++)); do
  case "${unlock_options[i]}" in
    --no-password) password_mode=Skip;;
    -k|--key-file|-y|--yubikey) ((i += 1));;
  esac
done
if [[ "$password_mode" == Skip ]]; then
  database_password=''
else
  read -r -s -p 'KeePass database password: ' database_password
  printf '\n' >&2
fi
keepass() {
  printf '%s\n' "$database_password" |
    "${cli[@]}" "$1" --quiet "${unlock_options[@]}" "$database" "${@:2}"
}

printf 'Exporting the AppImage signing key...\n'
fingerprint="$(gpg --batch --show-keys --with-colons "$HERE/packaging/appimage-update-key.asc" |
  awk -F: '$1 == "fpr" {print $10; exit}')"
test -n "$fingerprint"
gpg --homedir "$keys/gnupg" --batch --armor --export-secret-keys "$fingerprint" \
  > "$work/WN_APPIMAGE_SIGNING_KEY.asc"
test -s "$work/WN_APPIMAGE_SIGNING_KEY.asc"
cp -- "$keys/sparkle-seed.base64" "$work/WN_SPARKLE_PRIVATE_KEY.txt"
cp -- "$keys/sparkle-private.pem" "$work/sparkle-private.pem"

printf 'Creating KeePass entry: %s\n' "$entry"
if ! keepass add "$entry" --notes 'AppImage and Sparkle release signing keys.' > /dev/null 2> "$work/create-error"; then
  if ! keepass show "$entry" --attributes Title >/dev/null; then
    cat "$work/create-error" >&2
    exit 1
  fi
  printf 'Checking existing KeePass entry.\n'
fi
attachments=(WN_APPIMAGE_SIGNING_KEY.asc WN_SPARKLE_PRIVATE_KEY.txt sparkle-private.pem)
# Check every existing attachment before adding anything to a partial backup.
for name in "${attachments[@]}"; do
  if keepass attachment-export "$entry" "$name" "$work/verified-$name" > /dev/null 2> "$work/export-error"; then
    if ! cmp -s -- "$work/$name" "$work/verified-$name"; then
      printf 'Stored attachment differs: %s. Nothing was overwritten.\n' "$name" >&2
      exit 1
    fi
  else
    rm -f -- "$work/verified-$name"
  fi
done
for name in "${attachments[@]}"; do
  if [[ -f "$work/verified-$name" ]]; then
    printf 'Verified existing %s.\n' "$name"
    continue
  fi
  printf 'Importing and verifying %s...\n' "$name"
  keepass attachment-import "$entry" "$name" "$work/$name" >/dev/null
  keepass attachment-export "$entry" "$name" "$work/verified-$name" >/dev/null
  if ! cmp -s -- "$work/$name" "$work/verified-$name"; then
    printf 'Verification failed for %s. Source keys were not removed.\n' "$name" >&2
    exit 1
  fi
done
printf 'Verified three attachments in KeePass. Source keys remain in %s\n' "$keys"
