#!/usr/bin/env bash
set -euo pipefail

op=${1:?Expected start, run, push, pull, or stop}
shift
if [[ $GITHUB_EVENT_NAME == pull_request ]]; then
  case "$op" in
    start | run | stop) exec bash scripts/ci-container.sh "$op" "$@" ;;
    push | pull) exit 0 ;;
  esac
fi

state="$RUNNER_TEMP/wn-boat"
cli="$state/boat"
receipt="$state/sandbox.jsonl"
export BOAT_NO_UPDATE=1 BOAT_API_KEY="${BOAT_CI_KEY:?Missing the scoped Boat key}"

if [[ $op == start ]]; then
  kind=${1:?Expected a build environment}
  size=${2:-large}
  mkdir -p "$state"
  curl -fsSL 'https://github.com/ariana-dot-dev/agent-server/releases/download/boat-cli-v1.0.105/boat-linux-x64' -o "$cli"
  printf '%s  %s\n' 9f2fb5529ad7ca58e4d724bb6bfcd6ff94cb3077a7c12a0941e501aa0e9335ec "$cli" | sha256sum -c -
  chmod 700 "$cli"
  printf '%s\n' "$kind" >"$state/kind"
  "$cli" new --type "$size" --name "wn-gh-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT-$GITHUB_JOB-$(hostname -s)" \
    --environment wn-github-build --no-snapshots --ttl 11400 --json | tee "$receipt"
fi

if [[ $op == stop ]]; then
  if [[ -s $receipt ]]; then
    id=$(jq -r 'select(.event == "created") | .id' "$receipt")
    if [[ -n $id ]]; then "$cli" delete "$id" --yes --json; fi
  fi
  exit 0
fi

id=$(jq -er 'select(.event == "ready") | .id' "$receipt")
kind=$(<"$state/kind")
case "$op" in
  start)
    git archive --format=tar.gz HEAD >"$state/source.tar.gz"
    "$cli" scp "$state/source.tar.gz" "$id:wn-source.tar.gz"
    "$cli" ssh "$id" -- 'mkdir wn-ci wn-runner-temp && tar xzf wn-source.tar.gz -C wn-ci && rm wn-source.tar.gz'
    if [[ $kind != openbsd ]]; then
      printf 'bash scripts/ci-container.sh start %q\n' "$kind" >"$state/start.sh"
      WN_BOAT_HOST_STEP=1 bash "$0" run "$state/start.sh"
    fi
    ;;
  run)
    . scripts/ci-job-vars.sh
    {
      printf '%s\n' 'set -euo pipefail' 'cd "$HOME/wn-ci"' \
        'export GITHUB_WORKSPACE="$PWD" RUNNER_TEMP="$HOME/wn-runner-temp"'
      for var in "${ci_job_vars[@]}"; do
        if [[ $var == RUNNER_TEMP ]]; then continue; fi
        if [[ -v $var ]]; then printf 'export %s=%q\n' "$var" "${!var}"; fi
      done
      if [[ $kind == openbsd || ${WN_BOAT_HOST_STEP:-} == 1 ]]; then
        cat -- "${1:?Expected a workflow script}"
      else
        printf '%s\n' 'step=$(mktemp "$RUNNER_TEMP/step.XXXXXXXX")' 'trap '\''rm -f "$step"'\'' EXIT'
        printf 'printf %%s %q > "$step"\n' "$(<"${1:?Expected a workflow script}")"
        printf '%s\n' 'bash scripts/ci-container.sh run "$step"'
      fi
    } | "$cli" ssh "$id" -- 'bash -s'
    ;;
  push)
    tar -cf - -- "$@" | "$cli" ssh "$id" -- 'cd "$HOME/wn-ci" && tar -xf -'
    ;;
  pull)
    printf -v paths ' %q' "$@"
    "$cli" ssh "$id" -- "cd \"\$HOME/wn-ci\" && tar -cf - --$paths" | tar -xf -
    ;;
  *)
    echo "Unknown Boat operation: $op" >&2
    exit 2
    ;;
esac
