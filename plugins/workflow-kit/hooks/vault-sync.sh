#!/usr/bin/env bash
# vault-sync.sh — PostToolUse hook for workflow-kit.
#
# At most every ten minutes per session directory, detach a commit/pull/push of its vault.
# Runs silently and exits 0 on every failure; the child records Git output.
# Off switch: WORKFLOW_KIT_VAULT_SYNC=0.
#
# State directory: ${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/workflow-kit-vault-sync-$UID/
#   <project key>.stamp — epoch seconds of the last attempted launch
#   <vault key>.lock    — atomically published owner PID; stale abandoned locks reclaimed
#   <vault key>.lock.guard — OS lock serializing acquisition/reclamation
#   <vault key>.log     — output of the latest resolved-vault run (overwritten)

exec >/dev/null 2>&1
state=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/workflow-kit-vault-sync-$UID

# Encode every non-alphanumeric byte, including underscore, without forking.
path_key() {
    local LC_ALL=C input=$1 char encoded i
    key=
    for ((i=0; i<${#input}; i++)); do
        char=${input:i:1}
        case $char in
            [A-Za-z0-9]) key+=$char ;;
            *) printf -v encoded '_%02x' "'$char"; key+=$encoded ;;
        esac
    done
    # Bound filenames without any process before the hook's due check.
    if (( ${#key} > 200 )); then
        key="${key:0:90}_${#key}_${key: -90}"
    fi
}

private_state() {
    [[ ! -L $state ]] || return 1
    if [[ ! -d $state ]]; then
        mkdir -m 700 "$state" || return 1
    fi
    [[ -O $state && ! -L $state ]] || return 1
    chmod 700 "$state" || return 1
}

safe_file() {
    [[ ! -L $1 && ( ! -e $1 || ( -f $1 && -O $1 ) ) ]]
}

if [[ $# == 0 ]]; then
    [[ ${WORKFLOW_KIT_VAULT_SYNC:-1} == 0 ]] && exit 0
    project=${CLAUDE_PROJECT_DIR:-$PWD}
    path_key "$project"
    last=0
    if [[ -O $state && ! -L $state && -f "$state/$key.stamp" && ! -L "$state/$key.stamp" ]]; then
        read -r last < "$state/$key.stamp" || last=0
        [[ $last =~ ^[0-9]+$ ]] || last=0
    fi
    now=${EPOCHSECONDS:-$(date +%s)}
    [[ $now =~ ^[0-9]+$ ]] || exit 0
    (( 10#$last <= now && now - 10#$last < 600 )) && exit 0

    private_state || exit 0
    safe_file "$state/$key.stamp" || exit 0
    printf '%s\n' "$now" > "$state/$key.stamp" || exit 0
    if command -v setsid >/dev/null 2>&1; then
        setsid bash "$0" --run "$project" </dev/null >/dev/null 2>&1 &
    else
        nohup bash "$0" --run "$project" </dev/null >/dev/null 2>&1 &
        disown
    fi
    exit 0
fi

[[ $# == 2 && $1 == --run ]] || exit 0
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_NAMESPACE
project=$2
if common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir); then
    if [[ ${common##*/} == .git ]]; then
        project=${common%/*}
    else
        worktrees=$(git -C "$project" worktree list --porcelain) || exit 0
        candidate= bare=0
        while IFS= read -r line; do
            case $line in
                'worktree '*) candidate=${line#worktree }; bare=0 ;;
                bare) bare=1 ;;
                '')
                    if [[ -n $candidate && $bare == 0 ]]; then
                        project=$candidate
                        break
                    fi ;;
            esac
        done <<< "$worktrees"$'\n'
    fi
fi
resolved=$(python3 "$(dirname "$0")/../skills/pm/scripts/dossier.py" resolve-vault --project-dir "$project") || exit 0
vault=$(printf '%s\n' "$resolved" | python3 -c 'import json,sys; v=json.load(sys.stdin)["vault"]; sys.exit(1) if not isinstance(v,str) or not v else print(v)') || exit 0
path_key "$vault"
private_state || exit 0

real_vault=$(cd "$vault" && pwd -P) || exit 0
vault_top=$(git -C "$vault" rev-parse --show-toplevel) || exit 0
[[ $vault_top == "$real_vault" ]] || exit 0
project_top=$(git -C "$project" rev-parse --show-toplevel) || project_top=
[[ $vault_top != "$project_top" ]] || exit 0

lock="$state/$key.lock"
safe_file "$lock.guard" || exit 0
# Build a complete lock privately, then atomically rename it into place.
# Python supplies portable rename/stat behavior on both macOS and Linux.
python3 - "$lock" "$$" <<'LOCK' || exit 0
import fcntl
import os
import pathlib
import shutil
import sys
import tempfile
import time

lock = pathlib.Path(sys.argv[1])
pid = sys.argv[2]
# Keep this file in place: all reclaimers must lock the same inode. The OS
# releases flock even on SIGKILL; it covers only acquisition, never networking.
guard = open(str(lock) + ".guard", "a")
try:
    fcntl.flock(guard, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(1)
temp = pathlib.Path(tempfile.mkdtemp(prefix=".lock-", dir=lock.parent))
reclaim = lock / "reclaim"
marked = False

def owner():
    try:
        value = (lock / "pid").read_text().strip()
        return int(value) if value.isdigit() and int(value) > 0 else None
    except FileNotFoundError:
        return None

def live(value):
    if value is None:
        return False
    try:
        os.kill(value, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True

try:
    (temp / "pid").write_text(pid + "\n")
    if lock.exists():
        info = lock.lstat()
        if lock.is_symlink() or not lock.is_dir() or info.st_uid != os.getuid():
            sys.exit(1)
        previous = owner()
        old = time.time() - info.st_mtime > 600
        if live(previous) or (previous is None and not old):
            sys.exit(1)
        # Recover a marker abandoned by a killed reclaimer after the age limit.
        if old and reclaim.is_dir() and not reclaim.is_symlink():
            reclaim.rmdir()
        reclaim.mkdir()
        marked = True
        current = lock.stat()
        if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
            sys.exit(1)
        if owner() != previous or live(previous):
            sys.exit(1)
        (lock / "pid").unlink(missing_ok=True)
        reclaim.rmdir()
        marked = False
        lock.rmdir()
    # Existing populated locks cannot be replaced by rename. Fresh PID-less
    # leftovers were rejected above; this script never publishes one.
    os.rename(temp, lock)
except (OSError, ValueError):
    sys.exit(1)
finally:
    if marked:
        try:
            reclaim.rmdir()
        except OSError:
            pass
    if temp.exists():
        shutil.rmtree(temp)
LOCK
release_lock() {
    local owner
    read -r owner < "$lock/pid" || return
    if [[ $owner == "$$" ]]; then
        # A delayed reclaimer may have left its marker in our new lock.
        rmdir "$lock/reclaim" 2>/dev/null
        rm -f "$lock/pull.stderr"
        rm "$lock/pid"
        rmdir "$lock"
    fi
}
trap release_lock EXIT
trap 'exit 0' HUP INT TERM
safe_file "$state/$key.log" || exit 0
exec > "$state/$key.log" 2>&1 || exit 0

git -C "$vault" symbolic-ref -q HEAD >/dev/null || exit 0
for marker in index.lock rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG sequencer; do
    path=$(git -C "$vault" rev-parse --git-path "$marker") || exit 0
    [[ $path == /* ]] || path="$vault/$path"
    [[ ! -e $path ]] || exit 0
done

unmerged=$(git -C "$vault" ls-files -u) || exit 0
[[ -z $unmerged ]] || exit 0

export GIT_TERMINAL_PROMPT=0
[[ ${GIT_HTTP_LOW_SPEED_LIMIT+x} == x ]] || export GIT_HTTP_LOW_SPEED_LIMIT=1000
[[ ${GIT_HTTP_LOW_SPEED_TIME+x} == x ]] || export GIT_HTTP_LOW_SPEED_TIME=60
if [[ ${GIT_SSH_COMMAND+x} != x && ${GIT_SSH+x} != x ]] &&
    [[ -z $(git -C "$vault" config core.sshCommand) ]]; then
    export GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3'
fi
status=$(git -C "$vault" status --porcelain) || exit 0
if [[ -n $status ]]; then
    git -C "$vault" add -A || exit 0
    git -C "$vault" commit -m 'vault: auto-sync' || exit 0
fi
if git -C "$vault" rev-parse --abbrev-ref '@{u}'; then
    # Recheck and record HEAD so we can identify a rebase started by our pull.
    rebase_paths=()
    for marker in rebase-merge rebase-apply; do
        path=$(git -C "$vault" rev-parse --git-path "$marker") || exit 0
        [[ $path == /* ]] || path="$vault/$path"
        [[ ! -e $path ]] || exit 0
        rebase_paths+=("$path")
    done
    before_pull=$(git -C "$vault" rev-parse HEAD) || exit 0
    pull_error="$lock/pull.stderr"
    if ! git -C "$vault" pull --rebase --autostash 2>"$pull_error"; then
        cat "$pull_error"
        # Git reports this when another process started a rebase during fetch.
        if grep -Eiq 'already.*rebase-(merge|apply)|rebase-(merge|apply).*already|rebase.*in progress' "$pull_error"; then
            rm "$pull_error"
            exit 0
        fi
        rm "$pull_error"
        for path in "${rebase_paths[@]}"; do
            orig_head=
            if [[ -f $path/orig-head ]] && read -r orig_head < "$path/orig-head" &&
                [[ $orig_head == "$before_pull" ]]; then
                git -C "$vault" rebase --abort
                break
            fi
        done
        exit 0
    fi
    if [[ -f $pull_error ]]; then
        cat "$pull_error"
        rm "$pull_error"
    fi
    git -C "$vault" push || exit 0
fi
exit 0
