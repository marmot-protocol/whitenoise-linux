#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update -qq
sudo apt-get install -y -qq --no-install-recommends podman catatonit uidmap slirp4netns fuse-overlayfs
image=docker.io/library/archlinux:base-devel
time podman pull "$image"

available_kib() { awk '/^MemAvailable:/ {print $2}' /proc/meminfo; }
reserve=$((8 * 1024 * 1024))
memory=$((($(available_kib) - reserve - 512 * 1024) * 1024))
if ((memory <= 0)); then
  echo 'Boat worker cannot keep an 8 GiB RAM reserve.' >&2
  exit 1
fi
swap=$(awk '/^SwapFree:/ {printf "%.0f\n", $2 * 1024}' /proc/meminfo)
quota=$(($(getconf _NPROCESSORS_ONLN) * 80000))
name=wn-arch-pilot
podman run --detach --name "$name" --init --privileged \
  --cpu-period 100000 --cpu-quota "$quota" --memory "${memory}b" --memory-swap "$((memory + swap))b" \
  --volume "$PWD:/work" --workdir /work --entrypoint sleep "$image" infinity
(
  while (($(available_kib) >= reserve)); do sleep 1; done
  echo 'Stopping the build to preserve 8 GiB of available RAM.' >&2
  podman kill "$name"
) &
guard=$!
trap 'kill "$guard" 2>/dev/null || true; wait "$guard" 2>/dev/null || true; podman rm -f "$name"' EXIT

time podman exec "$name" bash -euo pipefail -c '
  pacman -Syu --noconfirm --needed git
  source packaging/arch/whitenoise-linux-git/PKGBUILD
  pacman -S --noconfirm --needed "${depends[@]}" "${makedepends[@]}"
  curl -fsSL -o /tmp/odin.tar.gz "${source[1]}"
  echo "${sha256sums[1]}  /tmp/odin.tar.gz" | sha256sum -c -
  mkdir -p /opt/odin
  tar -xzf /tmp/odin.tar.gz -C /opt/odin --strip-components=1
  export PATH="/opt/odin:$PATH" CARGO_BUILD_JOBS=6 WN_BUILD_JOBS=6 CMAKE_BUILD_PARALLEL_LEVEL=6
  scripts/arch-package.sh
'
(cd dist && sha256sum -- *-archlinux-x86_64.tar.zst >SHA256SUMS.txt)
