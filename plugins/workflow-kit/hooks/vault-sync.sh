#!/usr/bin/env bash
# vault-sync.sh — PostToolUse hook for workflow-kit.
#
# At most every ten minutes per project, detach a commit/pull/push of its vault.
# Runs silently and exits 0 on every failure; the child records Git output.
# Off switch: WORKFLOW_KIT_VAULT_SYNC=0.
#
# State directory: ${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/workflow-kit-vault-sync-$UID/
#   <project key>.stamp — epoch seconds of the last attempted launch
#   <vault key>.lock    — mkdir lock with owner PID; reclaimed only when owner is dead
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
project=$2
if common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir); then
    if [[ ${common##*/} == .git ]]; then
        project=${common%/*}
    else
        worktrees=$(git -C "$project" worktree list --porcelain) || exit 0
        first=${worktrees%%$'\n'*}
        [[ $first == 'worktree '* ]] || exit 0
        project=${first#worktree }
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
if ! mkdir -m 700 "$lock"; then
    [[ -d $lock && ! -L $lock && -O $lock ]] || exit 0
    read -r owner < "$lock/pid" || exit 0
    [[ $owner =~ ^[1-9][0-9]*$ ]] || exit 0
    kill -0 "$owner" 2>/dev/null && exit 0
    # Serialize reclaimers; a lock without a PID may still be initializing.
    mkdir "$lock/reclaim" || exit 0
    read -r current < "$lock/pid" || exit 0
    if [[ $current != "$owner" ]] || kill -0 "$current" 2>/dev/null; then
        rmdir "$lock/reclaim"
        exit 0
    fi
    rm "$lock/pid" && rmdir "$lock/reclaim" && rmdir "$lock" || exit 0
    mkdir -m 700 "$lock" || exit 0
fi
printf '%s\n' "$$" > "$lock/pid" || exit 0
release_lock() {
    local owner
    read -r owner < "$lock/pid" || return
    if [[ $owner == "$$" ]]; then
        rm "$lock/pid"
        rmdir "$lock"
    fi
}
trap release_lock EXIT
trap 'exit 0' HUP INT TERM
safe_file "$state/$key.log" || exit 0
exec > "$state/$key.log" 2>&1 || exit 0

for marker in index.lock rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    path=$(git -C "$vault" rev-parse --git-path "$marker") || exit 0
    [[ $path == /* ]] || path="$vault/$path"
    [[ ! -e $path ]] || exit 0
done

unmerged=$(git -C "$vault" ls-files -u) || exit 0
[[ -z $unmerged ]] || exit 0

export GIT_TERMINAL_PROMPT=0
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
    # Recheck immediately before pull. Only abort a rebase absent at this point.
    rebase_paths=()
    for marker in rebase-merge rebase-apply; do
        path=$(git -C "$vault" rev-parse --git-path "$marker") || exit 0
        [[ $path == /* ]] || path="$vault/$path"
        [[ ! -e $path ]] || exit 0
        rebase_paths+=("$path")
    done
    if ! git -C "$vault" pull --rebase --autostash; then
        for path in "${rebase_paths[@]}"; do
            if [[ -e $path ]]; then
                git -C "$vault" rebase --abort
                break
            fi
        done
        exit 0
    fi
    git -C "$vault" push || exit 0
fi
exit 0
