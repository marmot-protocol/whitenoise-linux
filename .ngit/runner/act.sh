#!/usr/bin/env bash
set -euo pipefail

cache=/run/ngit-ci-act-cache
if ! mountpoint -q "$cache"; then
  echo 'ngit worker requires its repository/trust-scoped cache.' >&2
  exit 1
fi
work="$cache/worker"
install -d -m 0700 "$work"
export DOCKER_HOST=unix:///run/podman/podman.sock
sandbox_options="--privileged --volume=$work:/var/cache/wn-ci"
args=(--pull=false)
container_options=absent
while (($#)); do
  case "$1" in
  --container-options)
    if (($# < 2)); then
      echo 'act: --container-options requires a value' >&2
      exit 2
    fi
    args+=("$1" "$2 $sandbox_options")
    container_options=present
    shift 2
    ;;
  --container-options=*)
    args+=("$1 $sandbox_options")
    container_options=present
    shift
    ;;
  *)
    args+=("$1")
    shift
    ;;
  esac
done
if [ "$container_options" = absent ]; then
  args+=(--container-options "$sandbox_options")
fi
if /opt/ngit-ci/act "${args[@]}"; then
  result=0
else
  result=$?
fi
# Flush writeback before the adapter destroys the guest and releases its lease.
sync -f "$work"
exit "$result"
