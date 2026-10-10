#!/usr/bin/env bash
# Per-PR run lock for address-pr.
#
#   pr-lock.sh acquire <lock-path>          -> prints "locked <holder-pid>", exit 0
#                                              or "busy <pidfile contents>", exit 1
#   pr-lock.sh release <lock-path> <pid>    -> frees the lock held by <pid>
#
# The lock is held by a background `flock` in its own process group, so it
# survives this script and the Bash call that ran it. The holder writes its own
# PID to <lock-path>.pid only after flock has acquired the lock, so a matching
# pidfile proves this run holds it; a stale pidfile from another run never does.
set -u

usage() {
  echo "usage: pr-lock.sh acquire <lock-path> | release <lock-path> <pid>" >&2
  exit 2
}

[ $# -ge 2 ] || usage
cmd=$1
lock=$2

case "$cmd" in
  acquire)
    # -n: fail at once when another run holds the lock.
    # -o: close the lock fd before exec, so only the flock process holds it.
    # shellcheck disable=SC2016  # $PPID and $1 expand in the holder shell, not here.
    setsid flock -n -o "$lock" \
      sh -c 'echo "$PPID $(date -Is)" > "$1.pid"; exec sleep infinity' sh "$lock" \
      </dev/null >/dev/null 2>&1 &
    holder=$!
    for _ in $(seq 25); do
      if [ "$(cut -d' ' -f1 "$lock.pid" 2>/dev/null)" = "$holder" ] \
        && kill -0 "$holder" 2>/dev/null; then
        echo "locked $holder"
        exit 0
      fi
      kill -0 "$holder" 2>/dev/null || break
      sleep 0.2
    done
    kill -TERM -- "-$holder" 2>/dev/null
    echo "busy $(cat "$lock.pid" 2>/dev/null)"
    exit 1
    ;;
  release)
    [ $# -eq 3 ] || usage
    pid=$3
    # Kill the whole holder group: killing the flock PID alone leaves `sleep` running.
    kill -TERM -- "-$pid" 2>/dev/null
    for _ in $(seq 25); do
      pgrep -g "$pid" >/dev/null || break
      sleep 0.2
    done
    if flock -n "$lock" true; then
      [ "$(cut -d' ' -f1 "$lock.pid" 2>/dev/null)" = "$pid" ] && rm -f "$lock.pid"
      echo "released $pid"
      exit 0
    fi
    echo "still held: $(cat "$lock.pid" 2>/dev/null)" >&2
    exit 1
    ;;
  *)
    usage
    ;;
esac
