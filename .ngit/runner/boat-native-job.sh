#!/usr/bin/env bash
set -euo pipefail

root=/wn-ci
workflow=.ngit/act/workflows/pr-native.yml
image=localhost/wn-native-pilot
storage=(--root "$root/containers" --storage-opt overlay.mount_program=/usr/bin/fuse-overlayfs)

if [[ ${1:-} == --sdk ]]; then
  cgroup=$(awk -F: '$1 == 0 {print $3}' /proc/self/cgroup)
  [[ $cgroup == */wn-native-seed-sdk.service/engine ]]
  build_cgroup=${cgroup%/engine}/build
  mkdir "/sys/fs/cgroup$build_cgroup"
  exec podman "${storage[@]}" --cgroup-manager=cgroupfs build --cgroup-parent="$build_cgroup" \
    --layers=false -t "$image" -f .ngit/runner/Containerfile .ngit/runner
fi

if [[ ${WN_NATIVE_SEED_CHILD:-} == 1 ]]; then
  cd "$WN_NATIVE_SOURCE"
  if [[ $WN_NATIVE_MODE == seed ]]; then
    sdk=$(sha256sum .ngit/runner/Containerfile | cut -d' ' -f1)
    if [[ $sdk != "$(<"$root/sdk-recipe")" ]]; then
      systemd-run --unit=wn-native-seed-sdk --wait --pipe --collect \
        -p "CPUQuota=$WN_JOB_CPUS%" -p "MemoryMax=$WN_JOB_MEMORY_BYTES" -p MemorySwapMax=8G \
        -p Delegate=yes -p DelegateSubgroup=engine --setenv=HOME=/root \
        --working-directory="$PWD" /bin/bash /home/user/wn-job.sh --sdk
      printf '%s\n' "$sdk" > "$root/sdk-recipe"
    fi
  fi
  exec act pull_request -j native -W "$workflow" -P "ubuntu-24.04=$image" \
    -e "$WN_NATIVE_EVENT" --container-daemon-socket -
fi

mode=${1:?expected seed or verify}
origin=${2:?expected ngit URL}
sha=${3:?expected signed revision}
archive=$root/cargo-cache.tar
if [[ $mode == verify ]]; then
  printf '%s  %s\n' "${4:?expected SHA-256}" "$archive" | sha256sum -c -
else
  [[ $mode == seed ]]
fi

scratch=$(mktemp -d /tmp/wn-native-seed.XXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
WN_NATIVE_SOURCE=$scratch/repo
WN_NATIVE_EVENT=$scratch/event.json
export GIT_TERMINAL_PROMPT=0
mkdir "$WN_NATIVE_SOURCE"
git -C "$WN_NATIVE_SOURCE" init -q
git -C "$WN_NATIVE_SOURCE" fetch -q --depth=1 --no-tags "$origin" "$sha"
git -C "$WN_NATIVE_SOURCE" checkout -q -B master FETCH_HEAD
[[ $(git -C "$WN_NATIVE_SOURCE" rev-parse HEAD) == "$sha" ]]
printf '{"pull_request":{"head":{"sha":"%s","ref":"master"},"base":{"ref":"master"}}}\n' "$sha" > "$WN_NATIVE_EVENT"

if ! systemd-run --unit=wn-native-seed-job --wait --pipe --collect \
  --setenv=HOME=/root --setenv=WN_NATIVE_SEED_CHILD=1 --setenv="WN_NATIVE_MODE=$mode" \
  --setenv="WN_NATIVE_SOURCE=$WN_NATIVE_SOURCE" --setenv="WN_NATIVE_EVENT=$WN_NATIVE_EVENT" \
  /bin/bash /home/user/wn-guest.sh |& tee "$scratch/native.log"; then
  if systemctl is-active --quiet wn-native-seed-sdk.service; then
    systemctl stop wn-native-seed-sdk.service
  fi
  exit 1
fi
[[ $(git -C "$root/worktree" rev-parse HEAD) == "$sha" ]]
if [[ $mode == verify ]]; then
  awk '
    /==> Building release cdylib \+ staticlib/ { mdk=1 }
    mdk && /[[:space:]]Compiling[[:space:]]/ { misses++ }
    mdk && /Finished .*release.* profile/ { print; hit=1; mdk=0 }
    END {
      printf "MDK crates recompiled: %d\n", misses
      if (!hit || misses) exit 1
    }
  ' "$scratch/native.log"
  exit
fi

cd "$root"
cache=(worktree/build/cargo/native worktree/vendor/mdk rustup
  containers/volumes/wn-pilot-registry/_data containers/volumes/wn-pilot-git/_data)
tar --create --format=pax --pax-option=delete=atime,delete=ctime --file "$archive.new" "${cache[@]}"
mv -T "$archive.new" "$archive"
rm -rf -- "${cache[@]}"
rm -f cargo /wn-tools/{act,docker} worktree/build/{app,smoke} /home/user/wn-{act,guest,job}.sh
rm -rf -- /wn-scratch
swapoff /wn-job.swap
rm -- /wn-job.swap
sync -f "$archive"
sha256sum "$archive"
