#!/usr/bin/env bash
set -euo pipefail

act=/opt/wn-ci/act
if [[ ! -x $act ]]; then
  download=$(mktemp)
  trap 'rm -f "$download"' EXIT
  curl -fsSL --max-time 90 -o "$download" \
    https://github.com/nektos/act/releases/download/v0.2.86/act_Linux_x86_64.tar.gz
  printf '%s  %s\n' f83f11968f19c43bf439d18b279247eb9c95df5eb984e6eebf8aa0e433b270ba \
    "$download" | sha256sum -c -
  install -d -m 0755 "$(dirname "$act")"
  tar -xzf "$download" -C "$(dirname "$act")" act
fi

options="--cpu-period=100000 --cpu-quota=$((WN_JOB_CPUS * 1000))"
options+=" --memory=$WN_JOB_MEMORY_BYTES --memory-swap=$WN_JOB_MEMORY_SWAP --pids-limit=8192"
options+=" --volume=/wn-ci:/var/cache/wn-ci --volume=/wn-scratch:/tmp"
options+=" --volume=wn-pilot-registry:/usr/local/cargo/registry --volume=wn-pilot-git:/usr/local/cargo/git"
if [[ ${WN_BOAT_STAGING:-} == 1 ]]; then
  if [[ ${1:-} != push ]]; then
    echo 'Boat staging only runs push workflows' >&2
    exit 2
  fi
  previous=
  for arg; do
    if [[ $previous == -W && ${arg##*/} == release-android.yml ]]; then
      tar --extract --numeric-owner --file /wn-ci/android-cache.tar -C /wn-ci
      break
    fi
    previous=$arg
  done
  options+=" --privileged --volume=/wn-stage-containers:/var/lib/containers/storage"
fi
cargo_jobs=1
if cmp -s DEPS_PIN /wn-ci/worktree/DEPS_PIN && diff -qr patches /wn-ci/worktree/patches >/dev/null; then
  cargo_jobs=4
fi
exec "$act" "$@" --pull=false --concurrent-jobs=1 --env-file /dev/null --secret-file /dev/null \
  --container-options "$options" --env CI=true --env CARGO_BUILD_JOBS="$cargo_jobs" \
  --env WN_BUILD_JOBS=4 --env CMAKE_BUILD_PARALLEL_LEVEL=4
