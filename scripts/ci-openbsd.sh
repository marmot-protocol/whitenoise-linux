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
mkdir -p "$out"
tmp=$(mktemp -d)
unit="wn-openbsd-$$.scope"
cleanup() {
  if [[ -n ${vm_pid:-} ]]; then
    if systemctl --user is-active --quiet "$unit"; then systemctl --user stop "$unit"; fi
    wait "$vm_pid" || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
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
  -display none -monitor none -serial "file:$out/vm-console.log" &
vm_pid=$!
(
  while kill -0 "$vm_pid" 2>/dev/null; do
    if (($(available_kib) < reserve)); then
      echo 'Stopping OpenBSD to preserve 8 GiB of available RAM.' >&2
      systemctl --user stop "$unit"
      exit 1
    fi
    sleep 1
  done
) &
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
  tail -n 50 "$out/vm-console.log" >&2
  exit 1
fi
ssh "${ssh_args[@]}" runner@127.0.0.1 /usr/local/bin/bash -s <<'GUEST'
set -euo pipefail
sudo pkg_add -I bash git cmake ninja gmake coreutils llvm%21 rust unzip-- \
    sdl3 libarchive libwebp mpv poppler cairo curl glib2 ffmpeg zenity libnotify zstd
sudo fdisk -iy sd2
printf '/mnt/build * 100%%\n' | sudo disklabel -wA -T - sd2
sudo newfs /dev/rsd2a
sudo mkdir -p /mnt/build
sudo mount /dev/sd2a /mnt/build
sudo chown runner /mnt/build
mkdir -p /mnt/build/work
GUEST
export RSYNC_RSH="ssh -i $tmp/key -p 22022 -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$tmp/known_hosts"
rsync -a --no-owner --no-group --exclude=/build/ --exclude=/dist/ ./ runner@127.0.0.1:/mnt/build/work/
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
} | ssh "${ssh_args[@]}" runner@127.0.0.1 /usr/local/bin/bash -s
mkdir -p dist
rsync -a runner@127.0.0.1:/mnt/build/work/dist/ dist/
rsync -a runner@127.0.0.1:/mnt/build/work/build/openbsd/wn-odin-shot.png "$out/"
