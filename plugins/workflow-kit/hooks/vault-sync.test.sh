#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hook="$script_dir/vault-sync.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P)
background_started=0
cleanup() {
    if [[ $background_started == 1 ]]; then
        # The test launcher owns a session for the child, including Git children.
        # Wait for its completion marker before deleting any fixture directories.
        for ((i=0; i<100; i++)); do
            [[ -f "$tmp/child.done" ]] && break
            if [[ -f "$tmp/child.pid" ]]; then
                read -r child_pid < "$tmp/child.pid"
                kill -TERM -- "-$child_pid" 2>/dev/null || true
            fi
            sleep 0.1
        done
        [[ -f "$tmp/child.done" ]] || { printf 'background child did not stop\n' >&2; exit 1; }
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# No inherited Git paths, injected config, identity, or user hooks may escape
# the fixture. All Git repositories and state live beneath this temporary HOME.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
unset GIT_TEMPLATE_DIR GIT_SSH_COMMAND GIT_SSH
export HOME="$tmp/home" XDG_RUNTIME_DIR="$tmp/runtime"
export XDG_CONFIG_HOME="$tmp/config" CLAUDE_PROJECT_DIR="$tmp/project"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
export GIT_TERMINAL_PROMPT=0 PYTHONDONTWRITEBYTECODE=1
export WORKFLOW_KIT_VAULT_SYNC=1
mkdir -p "$HOME/Workspace/Obsidian" "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME"
project=$CLAUDE_PROJECT_DIR
vault="$HOME/Workspace/Obsidian/project-vault"
remote="$tmp/remote.git"
state="$XDG_RUNTIME_DIR/workflow-kit-vault-sync-$UID"
# Same reversible byte escaping as the hook, with no command substitution.
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
path_key 'my-app'; dash_key=$key
path_key 'my_app'; [[ $key != "$dash_key" ]]
path_key "$project"
stamp="$state/$key.stamp"
path_key "$vault"
vault_key=$key
lock="$state/$vault_key.lock"

git init -q -b main "$project"
git -C "$project" commit -qm initial --allow-empty
git init -q --bare -b main "$remote"
git -C "$remote" config receive.denyNonFastForwards true
git clone -q "$remote" "$vault" 2>"$tmp/clone.err"
printf 'initial\n' > "$vault/note.md"
git -C "$vault" add -A
git -C "$vault" commit -qm initial
git -C "$vault" push -qu origin main
pushed=$(git -C "$remote" rev-parse HEAD)
assert_push() {
    local current
    current=$(git -C "$remote" rev-parse HEAD)
    git -C "$remote" merge-base --is-ancestor "$pushed" "$current"
    git -C "$vault" merge-base --is-ancestor "$current" HEAD
    pushed=$current
}
silent() {
    "$@" >"$tmp/out" 2>"$tmp/err"
    [[ ! -s "$tmp/out" && ! -s "$tmp/err" ]]
}
run() { silent bash "$hook" --run "$project"; }

# Fresh stamp: unchanged metadata and no external commands before the due check.
mkdir -m 700 "$state"
mkdir "$tmp/spies"
printf '%s\n' "${EPOCHSECONDS:-$(date +%s)}" > "$stamp"
metadata=$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_mtime_ns,s.st_size)' "$stamp")
for command in date git python3; do
    cat > "$tmp/spies/$command" <<'SPY'
#!/bin/bash
printf 'unexpected fork\n' > "$XDG_RUNTIME_DIR/unexpected-fork"
exit 1
SPY
    chmod +x "$tmp/spies/$command"
done
# EPOCHSECONDS exists on modern Bash; Bash 3.2 legitimately needs date.
if [[ -n ${EPOCHSECONDS:-} ]]; then
    silent env PATH="$tmp/spies:$PATH" bash "$hook"
else
    silent bash "$hook"
fi
[[ ! -e "$XDG_RUNTIME_DIR/unexpected-fork" ]]
[[ $metadata == "$(python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(s.st_mtime_ns,s.st_size)' "$stamp")" ]]
[[ $(git -C "$vault" rev-parse HEAD) == "$pushed" ]]

# Opt-out must not even create a stamp.
rm "$stamp"
silent env WORKFLOW_KIT_VAULT_SYNC=0 bash "$hook"
[[ ! -e $stamp ]]

# Instrument only the detach launcher so cleanup can always reap the real child.
# The real hook, dossier resolver, and Git operations still run unchanged.
mkdir "$tmp/launchers"
cat > "$tmp/launchers/setsid" <<'LAUNCHER'
#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys

root = Path(os.environ["VAULT_SYNC_TEST_ROOT"])
assert sys.argv[1] == "bash", sys.argv
child = subprocess.Popen(sys.argv[1:], start_new_session=True)
(root / "child.pid").write_text(str(child.pid))
try:
    child.wait()
finally:
    (root / "child.done").touch()
LAUNCHER
chmod +x "$tmp/launchers/setsid"
export VAULT_SYNC_TEST_ROOT="$tmp"
# A future stamp (clock rollback) is due.
printf '%s\n' "$(( ${EPOCHSECONDS:-$(date +%s)} + 3600 ))" > "$stamp"

printf 'due edit\n' >> "$vault/note.md"
background_started=1
silent env PATH="$tmp/launchers:$PATH" bash "$hook"
[[ -s $stamp ]]
for ((i=0; i<100; i++)); do
    [[ -f "$tmp/child.done" ]] && break
    sleep 0.1
done
[[ -f "$tmp/child.done" ]]
[[ $(git -C "$remote" log -1 --format=%s) == 'vault: auto-sync' ]]
[[ -z $(git -C "$vault" status --porcelain) ]]
assert_push
[[ ! -d $lock && -f "$state/$vault_key.log" ]]

# Without an upstream, commit locally and leave the remote unchanged.
git -C "$vault" branch --unset-upstream
printf 'local edit\n' >> "$vault/note.md"
run
local_commit=$(git -C "$vault" rev-parse HEAD)
[[ $local_commit != "$pushed" ]]
[[ $(git -C "$vault" log -1 --format=%s) == 'vault: auto-sync' ]]
[[ $(git -C "$remote" rev-parse HEAD) == "$pushed" ]]

# A clean tree must still push a commit left local by an earlier run.
git -C "$vault" branch -qu origin/main
run
assert_push
[[ $pushed == "$local_commit" ]]

# Every in-progress marker skips changes without creating a commit.
for marker in index.lock rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    path=$(git -C "$vault" rev-parse --git-path "$marker")
    [[ $path == /* ]] || path="$vault/$path"
    touch "$path"
    printf 'blocked edit\n' >> "$vault/note.md"
    run
    [[ $(git -C "$vault" rev-parse HEAD) == "$pushed" ]]
    [[ -e $path ]] # Pre-existing rebase markers must survive untouched.
    rm "$path"
done

# Unmerged index entries without a sequencer marker must never be staged.
blob=$(git -C "$vault" rev-parse HEAD:note.md)
printf '100644 %s 1\tnote.md\n100644 %s 2\tnote.md\n100644 %s 3\tnote.md\n' "$blob" "$blob" "$blob" |
    git -C "$vault" update-index --index-info
run
[[ $(git -C "$vault" rev-parse HEAD) == "$pushed" ]]
[[ -n $(git -C "$vault" ls-files -u) ]]
printf '0 %040d\tnote.md\n100644 %s 0\tnote.md\n' 0 "$blob" |
    git -C "$vault" update-index --index-info

# A live owner keeps its lock even when old; a dead owner is reclaimed.
mkdir "$lock"
printf '%s\n' "$$" > "$lock/pid"
python3 -c 'import os,sys,time; t=time.time()-660; os.utime(sys.argv[1],(t,t))' "$lock"
run
[[ $(git -C "$vault" rev-parse HEAD) == "$pushed" ]]
[[ $(cat "$lock/pid") == "$$" ]]
# Reap a real child to obtain a dead PID, rather than guessing a PID number.
sleep 0 &
dead_pid=$!
wait "$dead_pid"
printf '%s\n' "$dead_pid" > "$lock/pid"
run
[[ ! -d $lock ]]
assert_push

# A PID-less lock may still be initializing and must never be reclaimed.
mkdir "$lock"
run
[[ -d $lock ]]
rmdir "$lock"

# SSH defaults must respect each supported user configuration source.
mkdir "$tmp/git-spy"
export VAULT_SYNC_REAL_GIT
VAULT_SYNC_REAL_GIT=$(command -v git)
cat > "$tmp/git-spy/git" <<'GITSPY'
#!/usr/bin/env bash
if [[ ${3:-} == status ]]; then
    printf '%s\n' "${GIT_SSH_COMMAND-unset}" > "$VAULT_SYNC_TEST_ROOT/ssh-command"
fi
exec "$VAULT_SYNC_REAL_GIT" "$@"
GITSPY
chmod +x "$tmp/git-spy/git"
silent env PATH="$tmp/git-spy:$PATH" bash "$hook" --run "$project"
[[ $(cat "$tmp/ssh-command") == 'ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3' ]]
git -C "$vault" config core.sshCommand 'ssh -i ~/.ssh/vault_key'
silent env PATH="$tmp/git-spy:$PATH" bash "$hook" --run "$project"
[[ $(cat "$tmp/ssh-command") == unset ]]
git -C "$vault" config --unset core.sshCommand
silent env PATH="$tmp/git-spy:$PATH" GIT_SSH=custom-ssh bash "$hook" --run "$project"
[[ $(cat "$tmp/ssh-command") == unset ]]
silent env PATH="$tmp/git-spy:$PATH" GIT_SSH_COMMAND='ssh -i custom' bash "$hook" --run "$project"
[[ $(cat "$tmp/ssh-command") == 'ssh -i custom' ]]

# Reject state, stamp, and log symlinks without changing their targets.
printf 'keep\n' > "$tmp/target"
rm "$stamp"
ln -s "$tmp/target" "$stamp"
silent bash "$hook"
[[ $(cat "$tmp/target") == keep ]]
rm "$stamp" "$state/$vault_key.log"
ln -s "$tmp/target" "$state/$vault_key.log"
run
[[ $(cat "$tmp/target") == keep ]]
rm "$state/$vault_key.log"
mkdir "$tmp/unsafe-runtime" "$tmp/state-target"
ln -s "$tmp/state-target" "$tmp/unsafe-runtime/workflow-kit-vault-sync-$UID"
silent env XDG_RUNTIME_DIR="$tmp/unsafe-runtime" bash "$hook"
[[ -z $(ls -A "$tmp/state-target") ]]
[[ $(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$state") == 0o700 ]]

# A project without Git may still configure its own external vault.
mkdir -p "$tmp/plain/.claude"
printf '{"pm":{"vault":"%s"}}\n' "$vault" > "$tmp/plain/.claude/workflow-kit.json"
printf 'plain project edit\n' >> "$vault/note.md"
silent bash "$hook" --run "$tmp/plain"
assert_push
[[ -z $(git -C "$vault" status --porcelain) ]]

# Sibling worktrees must resolve the main checkout's convention-based vault.
git -C "$project" worktree add -qb sibling "$tmp/sibling"
printf 'worktree edit\n' >> "$vault/note.md"
silent bash "$hook" --run "$tmp/sibling"
assert_push
[[ -z $(git -C "$vault" status --porcelain) ]]

# Clean vaults also pull remote-only commits.
git clone -q "$remote" "$tmp/writer"
printf 'remote-only\n' > "$tmp/writer/remote.md"
git -C "$tmp/writer" add -A
git -C "$tmp/writer" commit -qm remote-only
git -C "$tmp/writer" push -q
run
assert_push
[[ -f "$vault/remote.md" ]]

# Divergence on the same line must abort the rebase and retain the local commit.
printf 'remote conflict\n' > "$tmp/writer/note.md"
git -C "$tmp/writer" commit -qam remote-conflict
git -C "$tmp/writer" push -q
remote_conflict=$(git -C "$remote" rev-parse HEAD)
git -C "$remote" merge-base --is-ancestor "$pushed" "$remote_conflict"
printf 'local conflict\n' > "$vault/note.md"
run
[[ $(git -C "$vault" log -1 --format=%s) == 'vault: auto-sync' ]]
[[ $(cat "$vault/note.md") == 'local conflict' ]]
[[ -z $(git -C "$vault" status --porcelain) ]]
for marker in rebase-merge rebase-apply; do
    path=$(git -C "$vault" rev-parse --git-path "$marker")
    [[ $path == /* ]] || path="$vault/$path"
    [[ ! -e $path ]]
done
[[ $(git -C "$vault" rev-parse HEAD^) == "$pushed" ]]
[[ $(git -C "$remote" rev-parse HEAD) == "$remote_conflict" ]]

# Worktree sessions resolve the main checkout's configured vault. A vault inside
# that code repository must never be staged, including untracked sibling files.
mkdir -p "$project/.claude" "$project/nested-vault"
printf '{"pm":{"vault":"nested-vault"}}\n' > "$project/.claude/workflow-kit.json"
printf 'never stage\n' > "$project/nested-vault/note.md"
project_head=$(git -C "$project" rev-parse HEAD)
run
[[ $(git -C "$project" rev-parse HEAD) == "$project_head" ]]
[[ -z $(git -C "$project" diff --cached --name-only) ]]
silent bash "$hook" --run "$tmp/sibling"
[[ $(git -C "$project" rev-parse HEAD) == "$project_head" ]]
[[ -z $(git -C "$project" diff --cached --name-only) ]]

printf 'vault-sync.test.sh: pass\n'
