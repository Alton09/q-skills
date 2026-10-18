#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
lock="$script_dir/lock.py"
[ -x "$lock" ]
"$lock" --help >/dev/null
tmp=$(mktemp -d)
sleeper=
cleanup() {
  if [ -n "$sleeper" ]; then
    kill "$sleeper" 2>/dev/null || true
    wait "$sleeper" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
check() { python3 -c "import json,sys; $1"; }

repo="$tmp/repo"
git init -q "$repo"
git -C "$repo" -c user.name=Test -c user.email=test@example.com commit -qm initial --allow-empty
git -C "$repo" worktree add -qb sibling "$tmp/sibling"
path="$repo/.git/pm.lock"
export PM_LOCK_OWNER_PID=$$

# Empty status must not create a lock, a guard, or any other file.
find "$repo/.git" -type f | sort >"$tmp/before"
"$lock" status --project-dir "$repo" | check 'x=json.load(sys.stdin); assert x == {"held":False,"holder":None,"stale":False}, x'
find "$repo/.git" -type f | sort >"$tmp/after"
cmp "$tmp/before" "$tmp/after"

sleep 120 &
sleeper=$!
PM_LOCK_OWNER_PID=$sleeper "$lock" acquire --project-dir "$repo" | check 'x=json.load(sys.stdin); assert x["ok"] and not x["stale"] and not x["takenOver"], x; assert set(x["holder"]) == {"pid","host","cwd","startedAt"}, x'
[ -f "$path" ]
PM_LOCK_OWNER_PID=$sleeper "$lock" acquire --project-dir "$repo" | check 'x=json.load(sys.stdin); assert x["ok"] and not x["takenOver"], x'
cp "$path" "$tmp/held"
"$lock" acquire --project-dir "$repo" | check 'x=json.load(sys.stdin); assert not x["ok"] and not x["stale"] and not x["takenOver"] and x["holder"], x'
"$lock" release --project-dir "$repo" | check 'x=json.load(sys.stdin); assert x == {"ok":True,"released":False}, x'
"$lock" status --project-dir "$repo" | check 'x=json.load(sys.stdin); assert x["held"] and not x["stale"], x'
cmp "$path" "$tmp/held"

# Sibling worktrees use exactly the same common-dir lock.
"$lock" status --project-dir "$tmp/sibling" >"$tmp/status"
"$lock" status --project-dir "$repo" >"$tmp/status-main"
cmp "$tmp/status" "$tmp/status-main"
"$lock" acquire --project-dir "$tmp/sibling" | check 'x=json.load(sys.stdin); assert not x["ok"], x'
cmp "$path" "$tmp/held"

# Reap the original owner before asserting staleness and takeover.
kill "$sleeper"
wait "$sleeper" 2>/dev/null || true
sleeper=
"$lock" status --project-dir "$repo" | check 'x=json.load(sys.stdin); assert x["held"] and x["stale"], x'
cmp "$path" "$tmp/held"
"$lock" acquire --project-dir "$tmp/sibling" | check 'x=json.load(sys.stdin); assert x["ok"] and x["stale"] and x["takenOver"], x'

sleep 120 &
sleeper=$!
PM_LOCK_OWNER_PID=$sleeper "$lock" acquire --project-dir "$repo" --force | check 'x=json.load(sys.stdin); assert x["ok"] and not x["stale"] and x["takenOver"], x'
PM_LOCK_OWNER_PID=$sleeper "$lock" release --project-dir "$tmp/sibling" | check 'x=json.load(sys.stdin); assert x == {"ok":True,"released":True}, x'
[ ! -e "$path" ]
"$lock" release --project-dir "$repo" | check 'x=json.load(sys.stdin); assert x == {"ok":True,"released":False}, x'

# Exercise the real ps command format, ancestor walk, no-ancestor refusal,
# PID reuse detection, and concurrent acquisition without writing pycache.
PYTHONDONTWRITEBYTECODE=1 python3 - "$lock" "$repo" "$sleeper" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
from unittest.mock import patch

script, repo, other = sys.argv[1:]
spec = importlib.util.spec_from_file_location("pm_lock", script)
lock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lock)
os.environ.pop("PM_LOCK_OWNER_PID", None)
assert lock.process(os.getpid())[0] == os.getppid()
with patch.object(lock.os, "getppid", return_value=30), patch.object(lock.subprocess, "run") as run:
    run.side_effect = [subprocess.CompletedProcess([], 0, "20 sh\n"),
                       subprocess.CompletedProcess([], 0, "10 /opt/bin/claude\n")]
    assert lock.owner_pid() == 20
    assert run.call_args_list[0].args[0] == ["ps", "-o", "ppid=", "-o", "comm=", "-p", "30"]
with patch.object(lock, "process", return_value=None):
    result = lock.command(lock.parser().parse_args(["acquire", "--project-dir", repo]))
    assert not result["ok"] and result["reason"] == "no claude ancestor", result
    assert not (Path(repo) / ".git/pm.lock").exists()
holder = {"pid": os.getpid(), "host": socket.gethostname()}
with patch.object(lock, "process", return_value=(1, "sleep")):
    assert lock.is_stale(holder)
with patch.object(lock, "process", return_value=(1, "claude")):
    assert not lock.is_stale(holder)
holder["host"] = socket.gethostname() + "-remote"
assert not lock.is_stale(holder)

children = [subprocess.Popen([script, "acquire", "--project-dir", repo],
             env={**os.environ, "PM_LOCK_OWNER_PID": pid}, stdout=subprocess.PIPE, text=True)
            for pid in (str(os.getpid()), other)]
results = [json.loads(child.communicate()[0]) for child in children]
assert all(child.returncode == 0 for child in children)
assert sum(result["ok"] for result in results) == 1, results
PY

# Invalid project directories are usage errors with stderr only.
mkdir "$tmp/not-git"
code=0
"$lock" status --project-dir "$tmp/not-git" >"$tmp/out" 2>"$tmp/err" || code=$?
[ "$code" -eq 2 ]
[ ! -s "$tmp/out" ]
[[ $(cat "$tmp/err") == lock.py:* ]]

printf 'lock.test.sh: pass\n'
