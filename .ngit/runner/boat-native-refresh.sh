#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit
umask 077

install_dir=$(cd -- "$(dirname -- "$0")" && pwd)
state=${STATE_DIRECTORY:?}
origin=https://relay.ngit.dev/npub1ven4zk8xxw873876gx8y9g9l9fazkye9qnwnglcptgvfwxmygscqsxddfh/darkmatter-linux.git
signer=7AB150CC2B60BE6907308A4BDB92669D1CAA4E76
repo=$state/master.git
current=$state/current.json
master_ref=refs/heads/verified-master
export GIT_TERMINAL_PROMPT=0 GNUPGHOME=$state/gnupg

fail() { printf '%s\n' "$*" >&2; exit 1; }
boat() { timeout 180 "$install_dir/boat" --no-update --json "$@"; }
snapshot_id() {
  boat snapshots --limit 1 | jq -er --arg name "$1" '
    .named[] | select(.name == $name and .status == "ready") | .snapshotId
  '
}
trusted_revision() {
  timeout 120 git -C "$repo" fetch -q --no-tags "$origin" "$@"
  local sha signing_key
  sha=$(git -C "$repo" rev-parse FETCH_HEAD)
  signing_key=$(git -C "$repo" log -1 --format=%GP "$sha")
  [[ $signing_key == "$signer" ]] && git -C "$repo" verify-commit "$sha" >&2 ||
    fail "Untrusted ngit revision: $sha"
  printf '%s\n' "$sha"
}
master() {
  local prior sha
  local history=()
  prior=$(git -C "$repo" rev-parse "$master_ref")
  if [[ $(git -C "$repo" rev-parse --is-shallow-repository) == true ]]; then
    history=(--unshallow)
  fi
  sha=$(trusted_revision "${history[@]}" refs/heads/master)
  git -C "$repo" merge-base --is-ancestor "$prior" "$sha" ||
    fail "Verified master moved backward or diverged: $prior -> $sha"
  git -C "$repo" update-ref "$master_ref" "$sha" "$prior"
  printf '%s\n' "$sha"
}
inputs() {
  local sha=$1
  {
    git -C "$repo" show "$sha:DEPS_PIN" | grep -E '^mdk-commit = [0-9a-f]{40}$'
    # Include the ordered patch list and Cargo invocation, not the app build.
    git -C "$repo" show "$sha:scripts/build.sh" | awk '
      /^MDK_REPO=/ { in_mdk=1 }
      in_mdk { print }
      in_mdk && /^  native_env$/ { end=1; in_mdk=0 }
      END { if (!end) exit 1 }
    '
    git -C "$repo" ls-tree -r "$sha" -- patches | awk -F '\t' '$2 ~ /^patches\/mdk-.*\.patch$/'
    git -C "$repo" ls-tree "$sha" -- .ngit/runner/Containerfile .ngit/act/workflows/pr-native.yml \
      scripts/apply-mdk-patches.sh scripts/ngit-stage.sh
  } | sha256sum | cut -d' ' -f1
}

exec 9>"$state/refresh.lock"
flock -n 9 || fail 'Native snapshot refresh already running'
[[ -d $repo ]] || git init -q --bare "$repo"

if [[ ${1:-} == --adopt && $# == 3 ]]; then
  [[ ! -e $current && $2 =~ ^wn-ngit-native-[a-z0-9-]+-pax$ && $3 =~ ^[a-f0-9]{40}$ ]] ||
    fail 'Adopt requires an empty selector and a verified master snapshot'
  sha=$(trusted_revision --depth=1 "$3")
  [[ $sha == "$3" ]]
  key=$(inputs "$sha")
  id=$(snapshot_id "$2")
  git -C "$repo" update-ref "$master_ref" "$sha"
  jq -n --arg name "$2" --arg id "$id" --arg revision "$sha" --arg inputs "$key" \
    '{name:$name, snapshotId:$id, revision:$revision, inputs:$inputs}' > "$state/current.new"
  chmod 0644 "$state/current.new"
  mv -T "$state/current.new" "$current"
  exit
fi
[[ $# == 0 ]] || fail 'usage: boat-native-refresh.sh [--adopt SNAPSHOT REVISION]'
active=$(jq -er '.name | select(test("^wn-ngit-native-[a-z0-9-]+-pax$"))' "$current")
sha=$(master)
key=$(inputs "$sha")
if [[ $(jq -er .inputs "$current") == "$key" ]]; then
  echo "MDK inputs unchanged at $sha; keeping $active"
  exit
fi

attempts=$state/attempts.json
now=$(date +%s)
[[ -f $attempts ]] || printf '{}\n' > "$attempts"
if jq -e --arg key "$key" --argjson now "$now" \
  '(.[$key] // 0) + 3600 > $now' "$attempts" >/dev/null; then
  echo "Refresh for $key already attempted within the hour; keeping $active"
  exit
fi
[[ $(snapshot_id "$active") == "$(jq -er .snapshotId "$current")" ]] ||
  fail "Refresh key cannot read the runner's active snapshot: $active"
jq --arg key "$key" --argjson now "$now" \
  'with_entries(select(.value + 3600 > $now)) | .[$key] = $now' "$attempts" > "$state/attempts.new"
mv -T "$state/attempts.new" "$attempts"

tmp=$(mktemp -d "$state/run.XXXXXX")
seed= verify= candidate=
cleanup() {
  local rc=$? id
  for id in "$verify" "$seed"; do
    if [[ -n $id ]]; then
      timeout 30 "$install_dir/boat" --no-update delete "$id" --yes ||
        echo "Boat worker $id will expire at its TTL" >&2
    fi
  done
  if [[ -n $candidate ]] && [[ $(jq -r .name "$current") != "$candidate" ]]; then
    timeout 30 "$install_dir/boat" --no-update snapshot rm "$candidate" ||
      echo "Remove unused candidate $candidate if Boat saved it" >&2
  fi
  rm -rf -- "$tmp"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM
start_worker() {
  local dest=$1 from=$2 frames status=0 deadline
  shift 2
  frames=$(timeout 300 "$install_dir/boat" --no-update --json new --type large --from "$from" \
    --ttl 5400 --no-env --name "wn-ngit-native-$dest-${sha:0:12}" "$@") || status=$?
  local id
  id=$(jq -sr '[.[] | .id? | strings | select(test("^bx_[a-z0-9]+$"))][0] // ""' <<< "$frames")
  printf -v "$dest" '%s' "$id"
  [[ $status == 0 && -n $id ]] || fail "Boat could not start $dest: $frames"
  echo "$dest worker: $id from $from"
  deadline=$((SECONDS + 300))
  until timeout 20 "$install_dir/boat" --no-update --json info "$id" | jq -e '.sandbox.hydrated == true' >/dev/null; do
    (( SECONDS < deadline )) || fail "Boat restore timed out: $id"
    sleep 4
  done
  timeout 90 "$install_dir/boat" --no-update scp "$install_dir/boat-guest.sh" "$id:/home/user/wn-guest.sh"
  timeout 90 "$install_dir/boat" --no-update scp "$install_dir/boat-act.sh" "$id:/home/user/wn-act.sh"
  timeout 90 "$install_dir/boat" --no-update scp "$install_dir/boat-native-job.sh" "$id:/home/user/wn-job.sh"
}
run_worker() {
  local id=$1 mode=$2 expected=${3:-} exits
  local status=(0 0 0 0)
  timeout 3300 "$install_dir/boat" --no-update --json exec "$id" --stream --timeout 0 -- \
    sudo bash /home/user/wn-job.sh "$mode" "$origin" "$sha" "$expected" \
    | tee "$tmp/$mode.jsonl" | jq --unbuffered -rj '.data // empty' \
    | tee "$tmp/$mode.log" || status=("${PIPESTATUS[@]}")
  exits=$(jq -cs '[.[] | select(.type == "exit") | .exitCode]' "$tmp/$mode.jsonl") ||
    fail "Invalid Boat output for $mode worker $id (pipeline: ${status[*]})"
  [[ ${status[*]} == '0 0 0 0' && $exits == '[0]' ]] ||
    fail "Boat $mode worker $id failed (guest: $exits; pipeline: ${status[*]})"
}

start_worker seed "$active"
run_worker "$seed" seed
archive=$(awk '$2 == "/wn-ci/cargo-cache.tar" && length($1) == 64 {print $1}' "$tmp/seed.log")
[[ $archive =~ ^[a-f0-9]{64}$ ]] || fail 'Seed did not report the PAX archive checksum'
stop=$(boat stop "$seed" --yes | jq -er .operation.id)
deadline=$((SECONDS + 600))
while :; do
  status=$(boat stop "$seed" --status "$stop" | jq -er .stop.status)
  case $status in
    completed) break ;;
    pending|failing) (( SECONDS < deadline )) || fail "Boat stop timed out: $seed" ;;
    *) fail "Boat stop failed: $status" ;;
  esac
  sleep 5
done

uuid=$(cat /proc/sys/kernel/random/uuid)
candidate=wn-ngit-native-auto-${sha:0:12}-${uuid:0:16}-pax
boat snapshot "$seed" "$candidate" | jq -se --arg name "$candidate" 'any(.[]; .event == "saved" and .name == $name)' >/dev/null
id=$(snapshot_id "$candidate")
start_worker verify "$candidate" --no-snapshots
run_worker "$verify" verify "$archive"

latest=$(master)
if [[ $(inputs "$latest") != "$key" ]]; then
  fail "MDK inputs changed again at $latest; keeping $active"
fi
[[ $(snapshot_id "$candidate") == "$id" ]] || fail "Boat replaced $candidate during verification"
retired=$(jq -r '.previous.name // ""' "$current")
jq --arg name "$candidate" --arg id "$id" --arg revision "$sha" --arg inputs "$key" \
  '{name:$name, snapshotId:$id, revision:$revision, inputs:$inputs, previous:del(.previous)}' \
  "$current" > "$state/current.new"
chmod 0644 "$state/current.new"
mv -T "$state/current.new" "$current"
echo "Activated $candidate at $sha; rollback: $active"
candidate=
if [[ $retired =~ ^wn-ngit-native-auto-[a-f0-9]{12}-[a-f0-9-]{16}-pax$ && $retired != "$active" ]]; then
  boat snapshot rm "$retired"
fi
