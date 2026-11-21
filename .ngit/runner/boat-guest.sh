#!/usr/bin/env bash
set -euo pipefail

export PATH=/wn-tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DOCKER_HOST=unix:///run/wn-ci/podman.sock
export GIT_TERMINAL_PROMPT=0
root=/wn-ci
image=localhost/wn-native-pilot
pod=(podman --root "$root/containers" --storage-opt overlay.mount_program=/usr/bin/fuse-overlayfs)

# Snapshot restore must be complete before opening the image or cache.
"${pod[@]}" image exists "$image"
tar --extract --numeric-owner --file "$root/cargo-cache.tar" -C "$root"
install -d -m 0755 /run/wn-ci /wn-tools
install -d -m 1777 /wn-scratch
if [[ ${WN_BOAT_STAGING:-} == 1 ]]; then
  install -d -m 0700 /wn-stage-containers
fi
ln -s /usr/local/cargo "$root/cargo"
install -m 0755 /home/user/wn-act.sh /wn-tools/act
ln -s /usr/bin/podman /wn-tools/docker

available_kib() { awk '/^MemAvailable:/ {print $2}' /proc/meminfo; }
reserve=$((8 * 1024 * 1024))
budget=$(( $(available_kib) - reserve - 512 * 1024 ))
if (( budget <= 0 )); then
  echo 'Boat worker cannot keep 8 GiB of RAM available' >&2
  exit 1
fi
swap=$((8 * 1024 * 1024 * 1024))
fallocate -l "$swap" /wn-job.swap
chmod 600 /wn-job.swap
mkswap /wn-job.swap
swapon /wn-job.swap
export WN_JOB_CPUS=$(( $(getconf _NPROCESSORS_ONLN) * 80 ))
export WN_JOB_MEMORY_BYTES=$(( budget * 1024 ))
export WN_JOB_MEMORY_SWAP=$(( WN_JOB_MEMORY_BYTES + swap ))

"${pod[@]}" system service --time=0 "$DOCKER_HOST" &
# The pinned coordinator checks daemon readiness with `docker info`.
export CONTAINER_HOST="$DOCKER_HOST"

script=/home/user/wn-job.sh
bash -s < "$script" &
job=$!
while [[ -n $(jobs -pr | grep -x "$job") ]]; do
  if (( $(available_kib) < reserve )); then
    echo 'Stopping Boat job to preserve 8 GiB of available RAM' >&2
    podman --remote kill --all
    exit 1
  fi
  sleep 1
done
rc=0
wait "$job" || rc=$?
if [[ ${WN_BOAT_STAGING:-} != 1 && -n ${1:-} && -d $1 ]] &&
    [[ -n $(find "$1" -mindepth 1 -print -quit) ]]; then
  echo 'The Boat PR worker does not publish artifacts' >&2
  exit 1
fi
exit "$rc"
