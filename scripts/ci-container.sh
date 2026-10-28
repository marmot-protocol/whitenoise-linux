#!/usr/bin/env bash
# Keep build environments in Podman and validated dependency state per runner slot.
set -euo pipefail

name="wn-ci-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}-${GITHUB_JOB:?}"
case "${1:-}" in
  start)
    kind="${2:?Expected native, cross, flatpak, or arch}"
    cache="$HOME/.cache/wn-github/$kind"
    args=()
    quota=$(($(getconf _NPROCESSORS_ONLN) * 80000))
    if ((quota > 640000)); then quota=640000; fi
    available=$(</proc/meminfo)
    available=${available#*MemAvailable:}
    available=${available%%kB*}
    memory=$((available * 1024 * 80 / 100))
    if ((memory > 24 * 1024 * 1024 * 1024)); then memory=$((24 * 1024 * 1024 * 1024)); fi
    limits=(--cpu-period 100000 --cpu-quota "$quota" --memory "${memory}b" --memory-swap "${memory}b")
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
        rustup="wn-ci-rustup-$kind-$key"
        if [ "$kind" = cross ]; then rustup="wn-rustup-$key"; fi
        args+=(-v "$rustup:/root/.rustup")
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

    # Checkout cleans the links, not these persistent targets. Build stamps and
    # Cargo still verify inputs; release archives and smoke evidence are not reused.
    for dir in build vendor; do
      mkdir -p "$cache/$dir"
      ln -s "$cache/$dir" "$dir"
    done
    mkdir -p "$cache/registry" "$cache/git" "$cache/vcpkg"
    podman run --detach --name "$name" --init "${limits[@]}" \
      --cap-drop=DAC_OVERRIDE --cap-drop=DAC_READ_SEARCH \
      -v "$GITHUB_WORKSPACE:/work" -v "$cache:$cache" \
      -v "$RUNNER_TEMP:$RUNNER_TEMP" \
      -v "$cache/registry:/root/.cargo/registry" -v "$cache/git:/root/.cargo/git" \
      -v "$cache/vcpkg:/root/.cache/vcpkg" \
      --workdir /work --entrypoint sleep "${args[@]}" "$image" infinity
    ;;
  run)
    args=()
    for var in \
      GITHUB_ACTIONS GITHUB_ACTION GITHUB_ENV GITHUB_OUTPUT GITHUB_PATH GITHUB_STEP_SUMMARY \
      GITHUB_EVENT_NAME GITHUB_EVENT_PATH GITHUB_REF GITHUB_REF_NAME GITHUB_REF_TYPE \
      GITHUB_SHA GITHUB_REPOSITORY GITHUB_REPOSITORY_OWNER GITHUB_RUN_ID GITHUB_RUN_ATTEMPT \
      GITHUB_JOB GITHUB_TOKEN RUNNER_TEMP \
      CARGO_BUILD_JOBS WN_BUILD_JOBS CMAKE_BUILD_PARALLEL_LEVEL \
      WN_RELEASE_VERSION WN_METRICS_WRITE_TOKEN WN_AUDIT_WRITE_TOKEN \
      WN_PACKAGE_APPIMAGE WN_APPIMAGE_SIGNING_KEY WN_VELOPACK_REPO \
      FLATPAK_STATE_DIR WN_FLATPAK_BUNDLE \
      JSIGN_STORETYPE JSIGN_ALIAS JSIGN_KEYSTORE JSIGN_KEYSTORE_SECRET \
      JSIGN_KEYSTORE_BASE64 JSIGN_STOREPASS RELEASE AUR_SSH_PRIVATE_KEY \
      ODIN_VERSION SDL_VERSION FLATPAK_ID APPIMAGE_EXTRACT_AND_RUN APPIMAGE_NAME \
      LINUXDEPLOY_VERSION LINUXDEPLOY_SHA256 APPIMAGETOOL_VERSION APPIMAGETOOL_SHA256; do
      if [[ -v $var ]]; then args+=(--env "$var"); fi
    done
    exec podman exec "${args[@]}" --env CI=true --env GITHUB_WORKSPACE=/work \
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
