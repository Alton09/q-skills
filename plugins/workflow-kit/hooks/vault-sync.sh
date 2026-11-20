#!/usr/bin/env bash
# vault-sync.sh — PostToolUse hook for workflow-kit.
#
# At most every ten minutes per project, detach a commit/pull/push of its vault.
# Runs silently and exits 0 on every failure; the child records Git output.
# Off switch: WORKFLOW_KIT_VAULT_SYNC=0.
#
# State directory: ${XDG_RUNTIME_DIR:-/tmp}/workflow-kit-vault-sync/
#   <project key>.stamp — epoch seconds of the last attempted launch
#   <vault key>.lock    — mkdir lock, reclaimed after ten minutes
#   <vault key>.log     — output of the latest resolved-vault run (overwritten)

exec >/dev/null 2>&1
state=${XDG_RUNTIME_DIR:-/tmp}/workflow-kit-vault-sync

if [[ $# == 0 ]]; then
    [[ ${WORKFLOW_KIT_VAULT_SYNC:-1} == 0 ]] && exit 0
    project=${CLAUDE_PROJECT_DIR:-$PWD}
    key=${project//[^A-Za-z0-9]/_}
    last=0
    if [[ -f "$state/$key.stamp" ]]; then
        read -r last < "$state/$key.stamp" || last=0
        [[ $last =~ ^[0-9]+$ ]] || last=0
    fi
    now=${EPOCHSECONDS:-$(date +%s)}
    [[ $now =~ ^[0-9]+$ ]] || exit 0
    (( now - 10#$last < 600 )) && exit 0

    mkdir -p "$state" || exit 0
    printf '%s\n' "$now" > "$state/$key.stamp" || exit 0
    if command -v setsid >/dev/null 2>&1; then
        setsid "$0" --run "$project" </dev/null >/dev/null 2>&1 &
    else
        nohup "$0" --run "$project" </dev/null >/dev/null 2>&1 &
        disown
    fi
    exit 0
fi

[[ $# == 2 && $1 == --run ]] || exit 0
project=$2
common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir) && project=${common%/*}
resolved=$(python3 "$(dirname "$0")/../skills/pm/scripts/dossier.py" resolve-vault --project-dir "$project") || exit 0
vault=$(printf '%s\n' "$resolved" | python3 -c 'import json,sys; v=json.load(sys.stdin)["vault"]; sys.exit(1) if not isinstance(v,str) or not v else print(v)') || exit 0
key=${vault//[^A-Za-z0-9]/_}
mkdir -p "$state" || exit 0
exec > "$state/$key.log" 2>&1 || exit 0

real_vault=$(cd "$vault" && pwd -P) || exit 0
vault_top=$(git -C "$vault" rev-parse --show-toplevel) || exit 0
[[ $vault_top == "$real_vault" ]] || exit 0
project_top=$(git -C "$project" rev-parse --show-toplevel) || exit 0
[[ $vault_top != "$project_top" ]] || exit 0

lock="$state/$key.lock"
if ! mkdir "$lock"; then
    find "$lock" -maxdepth 0 -type d -mmin +10 -exec rmdir {} \;
    mkdir "$lock" || exit 0
fi
trap 'rmdir "$lock"' EXIT
trap 'exit 0' HUP INT TERM

for marker in index.lock rebase-merge rebase-apply MERGE_HEAD; do
    path=$(git -C "$vault" rev-parse --git-path "$marker") || exit 0
    [[ $path == /* ]] || path="$vault/$path"
    [[ ! -e $path ]] || exit 0
done

export GIT_TERMINAL_PROMPT=0
if [[ ${GIT_SSH_COMMAND+x} != x ]]; then
    export GIT_SSH_COMMAND='ssh -o BatchMode=yes'
fi
status=$(git -C "$vault" status --porcelain) || exit 0
if [[ -n $status ]]; then
    git -C "$vault" add -A || exit 0
    git -C "$vault" commit -m 'vault: auto-sync' || exit 0
fi
if git -C "$vault" rev-parse --abbrev-ref '@{u}'; then
    if ! git -C "$vault" pull --rebase --autostash; then
        for marker in rebase-merge rebase-apply; do
            path=$(git -C "$vault" rev-parse --git-path "$marker") || exit 0
            [[ $path == /* ]] || path="$vault/$path"
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
