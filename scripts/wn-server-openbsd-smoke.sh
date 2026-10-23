#!/bin/bash
set -euo pipefail

here=$(pwd)
out="$here/build/openbsd"
cache="$HOME/.cache/wn-openbsd"
mkdir -p "$out" "$cache"
image="$cache/openbsd-7.9-x86-64.qcow2"
if [ ! -f "$image" ]; then
    curl -fL --retry 3 -o "$image" https://github.com/cross-platform-actions/openbsd-builder/releases/download/v0.14.0/openbsd-7.9-x86-64.qcow2
fi
printf '%s  %s\n' ad05bb9cdf8fb8edf0514ff4c30b124bf0067d20be6d14c49ebf89bbbc55a9c0 "$image" | sha256sum -c -
key="$out/vm-ssh-key"
if [ ! -f "$key" ]; then
    ssh-keygen -q -t ed25519 -N '' -f "$key"
fi
truncate -s 40M "$out/resources.raw"
mkfs.fat -F32 "$out/resources.raw"
mcopy -o -i "$out/resources.raw" "$key.pub" ::KEYS
if [ ! -f "$out/vm.qcow2" ]; then
    qemu-img create -f qcow2 -F qcow2 -b "$image" "$out/vm.qcow2"
fi
cp /usr/share/edk2/x64/OVMF_VARS.4m.fd "$out/OVMF_VARS.fd"
available=$(</proc/meminfo)
available=${available#*MemAvailable:}
available=${available%%kB*}
if ((available < 48 * 1024 * 1024)); then
    echo 'OpenBSD VM needs 40 GiB plus an 8 GiB host reserve.' >&2
    exit 1
fi
qemu-system-x86_64 -machine q35,accel=kvm -cpu host,-pdpe1gb -smp 12 -m 40G \
    -drive if=pflash,format=raw,unit=0,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd,readonly=on \
    -drive "if=pflash,format=raw,unit=1,file=$out/OVMF_VARS.fd" \
    -device virtio-scsi-pci -device scsi-hd,drive=os,bootindex=0 \
    -drive "if=none,file=$out/vm.qcow2,id=os,format=qcow2" \
    -device scsi-hd,drive=res -drive "if=none,file=$out/resources.raw,id=res,format=raw" \
    -device virtio-net-pci,netdev=net -netdev user,id=net,hostfwd=tcp:127.0.0.1:29847-:22 \
    -display none -monitor none -serial "file:$out/vm-console.log" &
vm_pid=$!
cleanup() {
    if kill -0 "$vm_pid" 2>/dev/null; then
        kill "$vm_pid"
    fi
}
trap cleanup EXIT
ssh_args=(-i "$key" -p 29847 -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$out/known_hosts")
ready=no
for attempt in $(seq 1 120); do
    if ssh "${ssh_args[@]}" runner@127.0.0.1 true 2>/dev/null; then
        ready=yes
        break
    fi
    if ! kill -0 "$vm_pid" 2>/dev/null; then
        echo 'OpenBSD VM exited before SSH was ready.' >&2
        exit 1
    fi
    sleep 2
done
if [ "$ready" != yes ]; then
    echo 'OpenBSD SSH readiness timed out; see vm-console.log.' >&2
    exit 1
fi
ssh "${ssh_args[@]}" runner@127.0.0.1 /usr/local/bin/bash -s <<'GUEST'
set -euo pipefail
sudo pkg_add -I bash git cmake ninja gmake coreutils llvm%21 rust unzip-- \
    sdl3 libarchive libwebp mpv poppler cairo curl glib2 ffmpeg zenity libnotify zstd
sudo sh -c 'ulimit -d unlimited; mkdir -p /mnt/scratch; mount_mfs -s 24g swap /mnt/scratch; chown runner /mnt/scratch'
mkdir -p /mnt/scratch/work
GUEST
export RSYNC_RSH="ssh -i $key -p 29847 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$out/known_hosts"
rsync -a --no-owner --no-group --exclude=/build/ --exclude=/dist/ --exclude=/vendor/mdk/target/ \
    --exclude=/vendor/mdk/crates/marmot-c/output/ --exclude='/vendor/llvm-mingw*' --exclude=/vendor/vcpkg/ \
    "$here/" runner@127.0.0.1:/mnt/scratch/work/
ssh "${ssh_args[@]}" runner@127.0.0.1 /usr/local/bin/bash -s <<'GUEST'
set -euo pipefail
cd /mnt/scratch/work
export CARGO_TARGET_DIR=/mnt/scratch/target CARGO_HOME=/mnt/scratch/cargo
bash scripts/openbsd-build.sh
GUEST
mkdir -p "$here/dist"
rsync -a runner@127.0.0.1:/mnt/scratch/work/dist/ "$here/dist/"
rsync -a --include='wn-odin-shot*.png' --exclude='*' runner@127.0.0.1:/mnt/scratch/work/build/openbsd/ "$out/"
