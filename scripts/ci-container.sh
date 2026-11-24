#!/usr/bin/env bash
# Keep build environments in job-local Podman containers.
set -euo pipefail

name="wn-ci-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}-${GITHUB_JOB:?}"
reserve=$((8 * 1024 * 1024))
available_kib() { awk '/^MemAvailable:/ {print $2}' /proc/meminfo; }
case "${1:-}" in
  start)
    kind="${2:?Expected native, cross, flatpak, or arch}"
    args=()
    if ! command -v podman >/dev/null; then
      sudo apt-get update
      sudo apt-get install -y --no-install-recommends podman catatonit uidmap slirp4netns fuse-overlayfs
    fi
    quota=$(($(getconf _NPROCESSORS_ONLN) * 80000))
    if ((quota > 640000)); then quota=640000; fi
    memory=$((($(available_kib) - reserve - 512 * 1024) * 1024))
    if ((memory <= 0)); then
      echo 'Cannot keep an 8 GiB RAM reserve on this runner.' >&2
      exit 1
    fi
    swap=$(awk '/^SwapFree:/ {printf "%.0f\n", $2 * 1024}' /proc/meminfo)
    limits=(--cpu-period 100000 --cpu-quota "$quota" --memory "${memory}b" --memory-swap "$((memory + swap))b")
    case "$kind" in
      native | cross)
        definition="packaging/ci/Containerfile"
        if [ "$kind" = cross ]; then definition=packaging/cross/Containerfile; fi
        key=$(sha256sum "$definition" | cut -d' ' -f1)
        image="localhost/wn-ci-$kind:$key"
        if [ "$kind" = cross ]; then image="localhost/whitenoise-cross:$key"; fi
        if ! podman image exists "$image"; then
          podman build --layers "${limits[@]}" -f "$definition" -t "$image" "$(dirname "$definition")"
        fi
        if [ "$kind" = native ]; then
          args+=(--cap-drop=DAC_OVERRIDE --cap-drop=DAC_READ_SEARCH)
        fi
        ;;
      flatpak)
        image=ghcr.io/flathub-infra/flatpak-github-actions:gnome-50
        args+=(--privileged)
        ;;
      arch)
        image=docker.io/library/archlinux:base-devel
        args+=(--privileged)
        ;;
      *)
        echo "Unknown CI container: $kind" >&2
        exit 2
        ;;
    esac

    podman run --detach --name "$name" --init "${limits[@]}" \
      -v "$GITHUB_WORKSPACE:/work" -v "$RUNNER_TEMP:$RUNNER_TEMP" \
      --workdir /work --entrypoint sleep "${args[@]}" "$image" infinity
    ;;
  run)
    . scripts/ci-job-vars.sh
    args=()
    for var in "${ci_job_vars[@]}"; do
      if [[ -v $var ]]; then args+=(--env "$var"); fi
    done
    if (($(available_kib) < reserve)); then
      echo 'Cannot keep an 8 GiB RAM reserve on this runner.' >&2
      exit 1
    fi
    (
      while (($(available_kib) >= reserve)); do sleep 1; done
      echo 'Stopping the build to preserve 8 GiB of available RAM.' >&2
      podman kill "$name"
    ) &
    guard=$!
    trap 'kill "$guard" 2>/dev/null || true; wait "$guard" 2>/dev/null || true' EXIT
    podman exec "${args[@]}" --env CI=true --env GITHUB_WORKSPACE=/work \
      "$name" bash -c 'export PATH="/opt/odin:$PATH"; exec bash --noprofile --norc -eo pipefail "$1"' \
      -- "${2:?Expected the workflow script path}"
    ;;
  stop)
    podman rm --force --ignore "$name"
    ;;
  *)
    echo "Usage: $0 start <native|cross|flatpak|arch> | run <script> | stop" >&2
    exit 2
    ;;
esac
