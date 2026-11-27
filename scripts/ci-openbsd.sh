#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update
sudo apt-get install -y --no-install-recommends acl dosfstools mtools ovmf qemu-system-x86 qemu-utils rsync
sudo setfacl -m "u:$(id -un):rw" /dev/kvm

reserve=$((8 * 1024 * 1024))
available_kib() { awk '/^MemAvailable:/ {print $2}' /proc/meminfo; }
budget=$(($(available_kib) - reserve - 512 * 1024))
guest_mib=$((budget / 1024 - 512))
if ((guest_mib < 4096)); then
  echo 'OpenBSD needs at least 4 GiB plus an 8 GiB host reserve.' >&2
  exit 1
fi
cpus=$(getconf _NPROCESSORS_ONLN)

out="$PWD/build/openbsd"
diagnostics="$out/diagnostics"
mkdir -p "$diagnostics"
cache_dir="$out/cargo-cache"
tmp=$(mktemp -d)
unit="wn-openbsd-$$.scope"
started=$(date '+%Y-%m-%d %H:%M:%S')
sample_memory() {
  local group
  group=$(systemctl --user show "$unit" --property=ControlGroup --value 2>/dev/null) || return
  if [[ -z $group ]]; then return 1; fi
  local dir="/sys/fs/cgroup$group"
  {
    date -u '+%FT%TZ' &&
    grep '^MemAvailable:' /proc/meminfo &&
    grep -H . "$dir"/memory.{current,peak,max,events}
  } >"$diagnostics/.memory.new" 2>/dev/null &&
    mv "$diagnostics/.memory.new" "$diagnostics/memory.log"
}

stop_vm() {
  systemctl --user stop "$unit" || kill "$vm_pid" 2>/dev/null
}

cleanup() {
  local status=$? vm_status=0
  if ((status != 0)) && [[ -n ${vm_pid:-} ]]; then
    # The scope can vanish on OOM. Keep the last sample and capture the host log.
    {
      printf 'Build exit: %s\nGuest RAM: %s MiB\n' "$status" "$guest_mib"
      if kill -0 "$vm_pid" 2>/dev/null; then
        echo 'QEMU still running at cleanup'
      else
        wait "$vm_pid" || vm_status=$?
        printf 'QEMU launcher exit: %s\n' "$vm_status"
      fi
      journalctl --user --unit "$unit" --since "$started" --no-pager || true
      sudo -n journalctl -k -b --since "$started" --no-pager 2>&1 |
        grep -Ei 'oom|out of memory|killed process|qemu|journal|sudo' || true
    } >"$diagnostics/host.log" || echo 'Could not write OpenBSD host diagnostics.' >&2
  fi
  if [[ -n ${vm_pid:-} ]]; then
    stop_vm 2>/dev/null || true
    wait "$vm_pid" || true
  fi
  if [[ -n ${watch_pid:-} ]]; then wait "$watch_pid" || true; fi
  rm -rf "$tmp"
  return "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

image="$tmp/openbsd.qcow2"
curl -fsSL --retry 3 -o "$image" https://github.com/cross-platform-actions/openbsd-builder/releases/download/v0.14.0/openbsd-7.9-x86-64.qcow2
printf '%s  %s\n' ad05bb9cdf8fb8edf0514ff4c30b124bf0067d20be6d14c49ebf89bbbc55a9c0 "$image" | sha256sum -c -
ssh-keygen -q -t ed25519 -N '' -f "$tmp/key"
truncate -s 40M "$tmp/resources.raw"
mkfs.fat -F32 "$tmp/resources.raw"
mcopy -o -i "$tmp/resources.raw" "$tmp/key.pub" ::KEYS
qemu-img create -f qcow2 -F qcow2 -b "$image" "$tmp/root.qcow2"
qemu-img create -f qcow2 "$tmp/build.qcow2" 64G
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$tmp/OVMF_VARS.fd"

systemd-run --user --scope --quiet --unit "$unit" \
  -p "CPUQuota=$((cpus * 80))%" -p "MemoryMax=$((budget * 1024))" \
  qemu-system-x86_64 -machine q35,accel=kvm -cpu host,-pdpe1gb -smp 4 -m "$guest_mib" \
  -drive if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on \
  -drive "if=pflash,format=raw,unit=1,file=$tmp/OVMF_VARS.fd" \
  -device virtio-scsi-pci -device scsi-hd,drive=os,bootindex=0 \
  -drive "if=none,file=$tmp/root.qcow2,id=os,format=qcow2" \
  -device scsi-hd,drive=res -drive "if=none,file=$tmp/resources.raw,id=res,format=raw" \
  -device scsi-hd,drive=build -drive "if=none,file=$tmp/build.qcow2,id=build,format=qcow2" \
  -device e1000,netdev=net -netdev user,id=net,hostfwd=tcp:127.0.0.1:22022-:22 \
  -display none -monitor none -serial "file:$diagnostics/vm-console.log" \
  >>"$diagnostics/qemu.log" 2>&1 &
vm_pid=$!
(
  while kill -0 "$vm_pid" 2>/dev/null; do
    sample_memory || true
    if (($(available_kib) < reserve)); then
      echo 'Stopping OpenBSD to preserve 8 GiB of available RAM.' | tee -a "$diagnostics/qemu.log" >&2 || true
      if stop_vm; then exit 1; fi
    fi
    sleep 1
  done
) &
watch_pid=$!
ssh_args=(-i "$tmp/key" -p 22022 -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$tmp/known_hosts")
ready=no
for attempt in $(seq 1 120); do
  if ssh "${ssh_args[@]}" runner@127.0.0.1 true 2>/dev/null; then
    ready=yes
    break
  fi
  if ! kill -0 "$vm_pid" 2>/dev/null; then break; fi
  sleep 2
done
if [[ $ready != yes ]]; then
  echo 'OpenBSD did not accept SSH.' >&2
  tail -n 50 "$diagnostics/vm-console.log" >&2 || true
  exit 1
fi
ssh "${ssh_args[@]}" runner@127.0.0.1 /usr/local/bin/bash -s <<'GUEST'
set -euo pipefail
sudo pkg_add -I bash git cmake ninja gmake coreutils llvm%21 rust unzip-- \
    sdl3 libarchive libwebp mpv poppler cairo curl glib2 ffmpeg zenity libnotify zstd gtar-- rsync
gtar --version
sudo fdisk -iy sd2
printf '/mnt/build * 100%%\n' | sudo disklabel -wA -T - sd2
sudo newfs /dev/rsd2a
sudo mkdir -p /mnt/build
sudo mount /dev/sd2a /mnt/build
sudo chown runner /mnt/build
mkdir -p /mnt/build/work
GUEST
export RSYNC_RSH="ssh -i $tmp/key -p 22022 -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$tmp/known_hosts"
guest=runner@127.0.0.1
if ! sdk=$(ssh "${ssh_args[@]}" "$guest" '/usr/local/bin/bash -o pipefail -c "pkg_info -q -S | LC_ALL=C sort | sha256 -q"'); then
  echo '::warning::OpenBSD SDK fingerprint unavailable. Building without the Cargo cache.'
  sdk=''
fi
restored=no
if [[ -n $sdk && -f $cache_dir/cache.tar.zst && -f $cache_dir/sdk && $(<"$cache_dir/sdk") == "$sdk" ]]; then
  if ssh "${ssh_args[@]}" "$guest" '/usr/local/bin/bash -o pipefail -c "zstd -dc | gtar -xf - -C /mnt/build"' \
    <"$cache_dir/cache.tar.zst"; then
    restored=yes
  else
    echo '::warning::OpenBSD Cargo cache could not be restored. Building from scratch.'
    ssh "${ssh_args[@]}" "$guest" 'rm -rf /mnt/build/cargo /mnt/build/target /mnt/build/work/vendor/mdk'
  fi
fi
printf 'OpenBSD Cargo cache restored: %s\n' "$restored"
# Cargo uses source mtimes. Keep them only for byte-identical staged inputs.
rsync -a --no-owner --no-group --checksum --no-times --delete --rsync-path=/usr/local/bin/rsync \
  --exclude=/build/ --exclude=/dist/ --exclude='*.env' ./ "$guest:/mnt/build/work/"
{
  printf 'export %s=%q\n' \
    WN_RELEASE_VERSION "${WN_RELEASE_VERSION:-}" \
    WN_METRICS_WRITE_TOKEN "${WN_METRICS_WRITE_TOKEN:-}" \
    WN_AUDIT_WRITE_TOKEN "${WN_AUDIT_WRITE_TOKEN:-}"
  cat <<'GUEST'
set -euo pipefail
cd /mnt/build/work
trap 'rm -f build/observability-tokens.toml' EXIT
export CARGO_TARGET_DIR=/mnt/build/target CARGO_HOME=/mnt/build/cargo
export CARGO_BUILD_JOBS=3 WN_BUILD_JOBS=3 CMAKE_BUILD_PARALLEL_LEVEL=3
bash scripts/openbsd-build.sh
GUEST
} | ssh "${ssh_args[@]}" "$guest" /usr/local/bin/bash -s || {
  status=$? inner_ssh=${PIPESTATUS[1]}
  printf 'OpenBSD guest build pipeline exited %s (SSH: %s).\n' "$status" "$inner_ssh" |
    tee "$diagnostics/guest-build-exit.log" >&2 || true
  exit "$status"
}
mkdir -p dist
rsync -a "$guest:/mnt/build/work/dist/" dist/
rsync -a "$guest:/mnt/build/work/build/openbsd/wn-odin-shot.png" "$out/"

if [[ -z ${WN_RC_TAG:-} || ${GITHUB_REF:-} != refs/heads/master ]]; then
  exit 0
fi
update="$out/cargo-cache-update"
if ! { rm -f "$update" && : >"$update"; }; then
  echo '::warning::OpenBSD Cargo cache update marker could not be created.'
  exit 0
fi
if [[ $restored == yes || -z $sdk ]]; then
  exit 0
fi

# Pax retains the subsecond mtimes Cargo uses to check freshness.
if ! { mkdir -p "$cache_dir" &&
  ssh "${ssh_args[@]}" "$guest" /usr/local/bin/bash -s >"$cache_dir/cache.tar.zst" <<'GUEST' &&
set -euo pipefail
cd /mnt/build
gtar --format=pax -cf - --exclude='*.env' --exclude=work/vendor/mdk/.git \
  --exclude=work/vendor/mdk/crates/marmot-c/output cargo/git cargo/registry target work/vendor/mdk | zstd -T2 -1
GUEST
  printf '%s\n' "$sdk" >"$cache_dir/sdk" &&
  printf '%s\n' "$sdk" >"$update.new" && mv -T "$update.new" "$update";
}; then
  echo '::warning::OpenBSD Cargo cache could not be saved.'
fi
