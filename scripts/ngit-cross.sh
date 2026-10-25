#!/usr/bin/env bash
set -euo pipefail

target="${1:?usage: ngit-cross.sh linux-arm64|windows-amd64}"
case "$target" in
linux-arm64 | windows-amd64) ;;
*)
  echo "Unsupported ngit cross target: $target" >&2
  exit 2
  ;;
esac

cache=/var/cache/wn-ci
key=$(sha256sum packaging/cross/Containerfile | cut -d' ' -f1)
image="localhost/whitenoise-cross:$key"
archive="$cache/images/cross-$key.oci"
smoke=""
trap 'rm -f "$archive.tmp"; if [ -n "$smoke" ]; then rm -rf "$smoke"; fi' EXIT
mkdir -p "$cache/images" "$cache/cross/registry" "$cache/cross/git" "$cache/vcpkg/archives"
if ! podman image exists "$image"; then
  if [ -f "$archive" ]; then
    podman load --input "$archive"
  else
    podman build --network=host --layers -f packaging/cross/Containerfile -t "$image" packaging/cross
    podman save --format oci-archive --output "$archive.tmp" "$image"
    mv "$archive.tmp" "$archive"
  fi
fi

rustup="$cache/cross/rustup-$key"
if [ ! -f "$rustup/settings.toml" ]; then
  mkdir -p "$rustup"
  podman run --rm --network=host --entrypoint tar "$image" -C /root/.rustup -cf - . | tar -C "$rustup" -xf -
fi
rm -rf dist build/cross-evidence
mkdir -p build/cross-evidence
podman run --rm --network=host --entrypoint bash \
  -e CARGO_BUILD_JOBS -e WN_BUILD_JOBS -e CMAKE_BUILD_PARALLEL_LEVEL \
  -e WN_RELEASE_VERSION -e WN_METRICS_WRITE_TOKEN -e WN_AUDIT_WRITE_TOKEN \
  -v "$PWD:/work" -v "$cache/vcpkg:/root/.cache/vcpkg" \
  -v "$cache/cross/registry:/root/.cargo/registry" \
  -v "$cache/cross/git:/root/.cargo/git" -v "$rustup:/root/.rustup" \
  "$image" scripts/cross-build.sh "$target"

version=$(bash scripts/version.sh)
smoke=$(mktemp -d)
if [ "$target" = windows-amd64 ]; then
  if [ -f dist/WhiteNoise-win-Portable.zip ]; then
    root="$smoke/package"
    unzip -q dist/WhiteNoise-win-Portable.zip -d "$root"
  else
    unzip -q "dist/WhiteNoise-$version-$target.zip" -d "$smoke"
    root="$smoke/WhiteNoise-$version-$target"
  fi
else
  tar -xzf "dist/WhiteNoise-$version-$target.tar.gz" -C "$smoke"
  root="$smoke/WhiteNoise-$version-$target"
fi
mounts=(-v "$root:/release:ro" -v "$PWD/scripts/cross-smoke.sh:/cross-smoke.sh:ro")
mounts+=(-v "$PWD/build/cross-evidence:/evidence")
args=("$target" /release)
if [ "$target" = linux-arm64 ]; then
  mounts+=(-v "$PWD/build/cross/linux-arm64/sysroot:/target-sysroot:ro")
  args+=(/target-sysroot)
fi
podman run --rm --network=host --init --workdir /evidence --entrypoint bash "${mounts[@]}" \
  "$image" /cross-smoke.sh "${args[@]}"
