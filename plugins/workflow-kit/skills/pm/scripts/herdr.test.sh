#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mirror="$script_dir/herdr.py"
[ -x "$mirror" ]
"$mirror" --help >/dev/null
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" HERDR_ENV=1
export HERDR_TEST_STATE="$tmp/state.json" HERDR_TEST_LOG="$tmp/argv.jsonl" CLAUDE_TEST_AGENTS="$tmp/agents.json"
unset WORKFLOW_KIT_HERDR HERDR_WORKSPACE_ID
mkdir -p "$HOME" "$tmp/bin" "$tmp/project/.claude" "$tmp/vault/Features/alpha/items"
export PATH="$tmp/bin:$PATH"
repo=$(cd "$tmp/project" && pwd -P)
vault="$tmp/vault"
items="$vault/Features/alpha/items"
item() { # item <slug> <worker> <session> <status> [stage]
  printf '%s\n' '---' "title: Item $1" "stage: ${5:-implement}" "status: $4" "worker: $2" "sessionId: $3" '---' >"$items/$1.md"
}
item one alpha-one aaaa1111-0000-0000-0000-000000000000 running
item two alpha-two-ci bbbb2222-0000-0000-0000-000000000000 running
item three alpha-three cccc3333-0000-0000-0000-000000000000 paused
item four alpha-four dddd4444-0000-0000-0000-000000000000 idle done
printf '%s\n' '[
 {"id":"aaaa1111","sessionId":"aaaa1111-0000-0000-0000-000000000000","name":"alpha-one","kind":"background","status":"busy","state":"working","startedAt":3},
 {"id":"aaaa9999","sessionId":"aaaa9999-0000-0000-0000-000000000000","name":"alpha-one-plan","kind":"background","status":"idle","state":"done","startedAt":1},
 {"id":"bbbb2222","sessionId":"bbbb2222-0000-0000-0000-000000000000","name":"alpha-two-ci","kind":"background","status":"busy","state":"working","startedAt":4},
 {"id":"cccc3333","sessionId":"cccc3333-0000-0000-0000-000000000000","name":"alpha-three","kind":"background","status":"idle","state":"done","startedAt":5},
 {"id":"dddd4444","sessionId":"dddd4444-0000-0000-0000-000000000000","name":"alpha-four","kind":"background","status":"busy","state":"working","startedAt":6},
 {"sessionId":"eeee5555-0000-0000-0000-000000000000","name":"pm-session","kind":"interactive","status":"busy"}
]' >"$CLAUDE_TEST_AGENTS"

cat >"$tmp/bin/claude" <<'SH'
#!/usr/bin/env bash
[ "$*" = "agents --json --all" ] || { echo "unexpected claude $*" >&2; exit 1; }
cat "$CLAUDE_TEST_AGENTS"
SH
cat >"$tmp/bin/herdr" <<'PY'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['HERDR_TEST_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\n')
if os.environ.get('HERDR_TEST_ERROR'):
    print(json.dumps({'error': {'code': 'server_error', 'message': 'fake herdr failure'}}), file=sys.stderr)
    sys.exit(1)
path = Path(os.environ['HERDR_TEST_STATE'])
state = json.loads(path.read_text()) if path.exists() else {'workspaces': [], 'panes': [], 'next': 0}
flag = lambda name: args[args.index(name) + 1]
pane_of = lambda pid: next(p for p in state['panes'] if p['pane_id'] == pid)
result = {}
cmd = args[:2]
if cmd == ['workspace', 'list']:
    result = {'workspaces': [{'workspace_id': w['workspace_id'], 'label': w['label']} for w in state['workspaces']]}
elif cmd == ['workspace', 'create']:
    state['next'] += 1
    ws = f"w{state['next']}"
    state['workspaces'].append({'workspace_id': ws, 'label': flag('--label')})
    pane = {'pane_id': f'{ws}:p1', 'workspace_id': ws, 'cwd': flag('--cwd'), 'fg': None}
    state['panes'].append(pane)
    result = {'workspace': {'workspace_id': ws}, 'tab': {'tab_id': f'{ws}:t1'}, 'root_pane': {'pane_id': pane['pane_id']}}
elif cmd == ['workspace', 'rename']:
    next(w for w in state['workspaces'] if w['workspace_id'] == args[2])['label'] = args[3]
elif cmd == ['workspace', 'close']:
    state['workspaces'] = [w for w in state['workspaces'] if w['workspace_id'] != args[2]]
    state['panes'] = [p for p in state['panes'] if p['workspace_id'] != args[2]]
elif cmd == ['pane', 'list']:
    result = {'panes': [{k: p[k] for k in ('pane_id', 'workspace_id', 'cwd')} for p in state['panes'] if p['workspace_id'] == flag('--workspace')]}
elif cmd == ['pane', 'run']:
    pane_of(args[2])['fg'] = args[3]
elif cmd == ['pane', 'process-info']:
    fg = pane_of(flag('--pane'))['fg']
    result = {'process_info': {'shell_pid': 100, 'foreground_process_group_id': 200 if fg else 100, 'foreground_processes': [{'pid': 200, 'cmdline': fg}] if fg else []}}
elif cmd == ['agent', 'get']:
    pane = pane_of(args[2])
    if not pane['fg'] or 'attach' not in pane['fg']:
        print(json.dumps({'error': {'code': 'agent_not_found', 'message': 'not found'}}), file=sys.stderr)
        sys.exit(1)
    result = {'agent': {'agent': 'claude', 'name': pane.get('name')}}
elif cmd == ['agent', 'rename']:
    pane_of(args[2])['name'] = args[3]
else:
    raise AssertionError(args)
path.write_text(json.dumps(state))
print(json.dumps({'id': 'fake', 'result': result}))
PY
chmod +x "$tmp/bin/herdr" "$tmp/bin/claude"
check() { python3 -c "import json,sys; $1"; }
run() { "$mirror" "$@"; }
spaces() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(" ".join(sorted(w["label"] for w in s["workspaces"])))' "$HERDR_TEST_STATE"; }
pane_cmd() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); ws=[w["workspace_id"] for w in s["workspaces"] if w["label"]==sys.argv[2]]; print([p["fg"] for p in s["panes"] if p["workspace_id"] in ws])' "$HERDR_TEST_STATE" "$1"; }

# Outside herdr every action skips before any item read, herdr call, or agents call.
for a in "available --project-dir $repo" "open --item missing --repo $repo" "close --item missing --repo $repo" "sync --vault $vault --repo $repo"; do
  # shellcheck disable=SC2086
  env -u HERDR_ENV "$mirror" $a | check 'x=json.load(sys.stdin); assert x["skipped"] is True, x'
done
[ ! -e "$HERDR_TEST_LOG" ]

# Configuration can disable every action; a bad pm.herdr exits 2 with stderr only.
printf '%s\n' '{"pm":{"herdr":false}}' >"$repo/.claude/workflow-kit.json"
run sync --vault "$vault" --repo "$repo" | check 'x=json.load(sys.stdin); assert x["skipped"] and "disabled" in x["reason"], x'
[ ! -e "$HERDR_TEST_LOG" ]
printf '%s\n' '{"pm":{"herdr":"false"}}' >"$repo/.claude/workflow-kit.json"
rc=0; err=$(run available --project-dir "$repo" 2>&1 >/dev/null) || rc=$?
[ "$rc" -eq 2 ] && case "$err" in *"pm.herdr: must be a boolean"*) ;; *) false ;; esac || { echo "bad config: rc=$rc err=$err" >&2; exit 1; }
printf '%s\n' '{}' >"$repo/.claude/workflow-kit.json"
run available --project-dir "$repo" | check 'x=json.load(sys.stdin); assert x == {"available":True,"reason":None}, x'

# open gives a running worker its own workspace in the repo, attached by short id, not by name.
# (alpha-one is a prefix of alpha-one-plan, so `claude attach alpha-one` would be ambiguous.)
ls -aR "$vault" >"$tmp/vault-before"
run open --item "$items/one.md" --repo "$repo" | check 'x=json.load(sys.stdin); assert x["opened"] and x["label"] == "pm:alpha-one" and x["agent"] == "alpha-one", x'
[ "$(pane_cmd pm:alpha-one)" = "['command claude attach aaaa1111']" ]
python3 - "$HERDR_TEST_STATE" "$repo" <<'PY'
import json, sys
state = json.load(open(sys.argv[1]))
assert state['panes'][0]['cwd'] == sys.argv[2] and state['panes'][0]['name'] == 'alpha-one', state
PY
# A second open is idempotent.
run open --item "$items/one.md" --repo "$repo" | check 'x=json.load(sys.stdin); assert x["opened"] is False and x["workspace"] == "w1", x'
[ "$(spaces)" = "pm:alpha-one" ]
# A relaunch with an unlisted session never attaches to or closes the previous session.
run open --worker alpha-one --session new-session --repo "$repo" | check 'x=json.load(sys.stdin); assert "session not listed yet" in x["warning"], x'
[ "$(pane_cmd pm:alpha-one)" = "['command claude attach aaaa1111']" ]
# An attach that exited is restarted in the same pane.
python3 - "$HERDR_TEST_STATE" <<'PY'
import json, sys
path = sys.argv[1]; state = json.load(open(path)); state['panes'][0]['fg'] = None; open(path, 'w').write(json.dumps(state))
PY
run open --item "$items/one.md" --repo "$repo" | check 'x=json.load(sys.stdin); assert x["opened"] and x["workspace"] == "w1", x'
# A finished worker gets no space.
run open --worker alpha-one-plan --repo "$repo" | check 'x=json.load(sys.stdin); assert x["opened"] is False and "finished" in x["reason"], x'
# An item-less worker (retro) opens by name.
run open --worker alpha-four --repo "$repo" | check 'x=json.load(sys.stdin); assert x["opened"], x'
[ "$(pane_cmd pm:alpha-four)" = "['command claude attach dddd4444']" ]

# sync opens running and paused workers, keeps live item-less ones, and closes finished ones.
python3 - "$CLAUDE_TEST_AGENTS" <<'PY'
import json, sys
path = sys.argv[1]; rows = json.load(open(path))
for row in rows:
    if row['name'] == 'alpha-one':
        row.update(status='idle', state='done')
open(path, 'w').write(json.dumps(rows))
PY
run sync --vault "$vault" --repo "$repo" | check 'x=json.load(sys.stdin); assert sorted(x["opened"]) == ["alpha-three", "alpha-two-ci"] and x["closed"] == ["alpha-one"] and x["kept"] == ["alpha-four"], x'
[ "$(spaces)" = "pm:alpha-four pm:alpha-three pm:alpha-two-ci" ]
run sync --vault "$vault" --repo "$repo" | check 'x=json.load(sys.stdin); assert x["opened"] == [] and x["closed"] == [], x'

# A stopped worker closes even while its item still says paused; so does a finished retro worker.
python3 - "$CLAUDE_TEST_AGENTS" <<'PY'
import json, sys
path = sys.argv[1]; rows = json.load(open(path))
for row in rows:
    if row['name'] == 'alpha-three':
        row.update(status='idle', state='stopped')
    if row['name'] == 'alpha-four':
        row.update(status='idle', state='done')
open(path, 'w').write(json.dumps(rows))
PY
run sync --vault "$vault" --repo "$repo" | check 'x=json.load(sys.stdin); assert sorted(x["closed"]) == ["alpha-four", "alpha-three"], x'
[ "$(spaces)" = "pm:alpha-two-ci" ]
# Sync wrote nothing into the vault.
ls -aR "$vault" >"$tmp/vault-after"
cmp "$tmp/vault-before" "$tmp/vault-after"

# Spaces of another repository, user spaces, and user processes are never closed.
python3 - "$HERDR_TEST_STATE" <<'PY'
import json, sys
path = sys.argv[1]; state = json.load(open(path))
state['workspaces'] += [{'workspace_id': 'wx', 'label': 'pm:gone'}, {'workspace_id': 'wy', 'label': 'Personal'}, {'workspace_id': 'wz', 'label': 'pm:alpha-two-ci'},
                        {'workspace_id': 'wd', 'label': 'codex:wt/done'}]
state['panes'] += [{'pane_id': 'wx:p1', 'workspace_id': 'wx', 'cwd': '/other/repo', 'fg': None},
                   {'pane_id': 'wy:p1', 'workspace_id': 'wy', 'cwd': '/x', 'fg': None},
                   {'pane_id': 'wz:p1', 'workspace_id': 'wz', 'cwd': '/other/repo', 'fg': None},
                   {'pane_id': 'wd:p1', 'workspace_id': 'wd', 'cwd': '/wt', 'fg': None}]
ours = next(w['workspace_id'] for w in state['workspaces'] if w['label'] == 'pm:alpha-two-ci')
for pane in state['panes']:
    if pane['workspace_id'] == ours:
        pane['fg'] = 'vim notes.md'
open(path, 'w').write(json.dumps(state))
PY
python3 - "$CLAUDE_TEST_AGENTS" <<'PY'
import json, sys
path = sys.argv[1]; rows = json.load(open(path))
for row in rows:
    if row['name'] == 'alpha-two-ci':
        row.update(status='idle', state='done')
open(path, 'w').write(json.dumps(rows))
PY
run sync --vault "$vault" --repo "$repo" | check 'x=json.load(sys.stdin); assert x["closed"] == [] and "did not start" in x["warning"] and x["swept"] == ["wd"], x'
[ "$(spaces)" = "Personal pm:alpha-two-ci pm:alpha-two-ci pm:gone" ]
run close --item "$items/two.md" --repo "$repo" | check 'x=json.load(sys.stdin); assert x["closed"] == [] and "did not start" in x["warning"], x'

# herdr and agents failures are one warning object with exit 0.
HERDR_TEST_ERROR=1 run sync --vault "$vault" --repo "$repo" | check 'x=json.load(sys.stdin); assert "fake herdr failure" in x["warning"], x'
printf 'not json' >"$CLAUDE_TEST_AGENTS"
run open --item "$items/one.md" --repo "$repo" | check 'x=json.load(sys.stdin); assert "claude agents" in x["warning"], x'

# Usage errors write stderr and exit 2, with no JSON.
printf '%s\n' '---' 'not valid frontmatter' '---' >"$items/bad.md"
printf '%s\n' '---' 'title: No worker' 'stage: implement' '---' >"$items/no-worker.md"
for bad_item in bad no-worker missing; do
  rc=0
  run open --item "$items/$bad_item.md" --repo "$repo" >"$tmp/bad.out" 2>"$tmp/bad.err" || rc=$?
  [ "$rc" -eq 2 ] && [ ! -s "$tmp/bad.out" ] || { echo "usage error case $bad_item: rc=$rc" >&2; exit 1; }
  case "$bad_item" in
    bad) expected='invalid frontmatter line' ;;
    no-worker) expected='item has no worker' ;;
    missing) expected='No such file or directory' ;;
  esac
  grep -q "$expected" "$tmp/bad.err"
done

python3 - "$script_dir" <<'PY'
import re, sys
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, sys.argv[1])
import herdr
for worker in ('', '123', '-abc', 'A B.C!', 'Ünicode', 'x' * 300, 'a-' + 'b' * 100, 'x' * 80 + '-ci', 'x' * 80 + '-comments'):
    assert re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', herdr.agent_name(worker)), worker
ci, comments = herdr.agent_name('x' * 80 + '-ci'), herdr.agent_name('x' * 80 + '-comments')
assert len(ci) == len(comments) == 32 and ci.endswith('-ci') and comments.endswith('-comments') and ci != comments
assert herdr.agent_name('alpha-one-ci') == 'alpha-one-ci'
# Liveness: running and waiting keep a space; done keeps it only for a paused item; stopped never does.
assert herdr.keep({'state': 'working'}, None) and herdr.keep({'state': 'done', 'status': 'waiting'}, None)
assert not herdr.keep({'state': 'done'}, {'status': 'running'}) and herdr.keep({'state': 'done'}, {'status': 'paused'})
assert not herdr.keep({'state': 'stopped'}, {'status': 'paused'}) and not herdr.keep(None, {'status': 'paused'})
# pick prefers the item's session over a newer same-name session.
rows = {'w': [{'id': 'new', 'sessionId': 'new-1', 'startedAt': 2}, {'id': 'old', 'sessionId': 'old-1', 'startedAt': 1}]}
assert herdr.pick(rows, 'w', 'old-1')['id'] == 'old' and herdr.pick(rows, 'w')['id'] == 'new'
assert herdr.pick(rows, 'w', 'missing') is None
assert herdr.short_id({'sessionId': '0123456789'}) == '01234567'
# Each close-loop failure stays local; opens and sweep still run and retain results.
record = {'id': 'live', 'state': 'working'}
repo = Path('/repo')
for failure in ('owned', 'close', 'process_info'):
    rows = [{'label': 'pm:bad', 'workspace_id': 'bad'}, {'label': 'pm:done', 'workspace_id': 'done'}]
    def owned(row, repo):
        if failure == 'owned' and row['workspace_id'] == 'bad':
            raise herdr.MirrorError('owned failed')
        return [{'pane_id': row['workspace_id'], 'cwd': str(repo)}]
    def close(row):
        if failure == 'close' and row['workspace_id'] == 'bad':
            raise herdr.MirrorError('close failed')
        herdr.space.process_info(row['workspace_id'])
        return True
    def info(pane):
        if failure == 'process_info' and pane == 'bad':
            raise herdr.MirrorError('process_info failed')
        return {}
    with patch.object(herdr, 'agents', return_value={'live': [record]}), \
         patch.object(herdr, 'active_items', return_value=[{'worker': 'live'}]), \
         patch.object(herdr.space, 'spaces', return_value=rows), \
         patch.object(herdr, 'owned', side_effect=owned), \
         patch.object(herdr.space, 'close_space', side_effect=close), \
         patch.object(herdr.space, 'process_info', side_effect=info), \
         patch.object(herdr, 'open_worker', return_value={'opened': True}) as opener, \
         patch.object(herdr.space, 'sweep', side_effect=herdr.MirrorError('sweep failed')) as sweeper:
        result = herdr.sync(Path('/vault'), repo)
        assert result['closed'] == ['done'] and result['opened'] == ['live'], result
        assert failure + ' failed' in result['warning'] and 'sweep failed' in result['warning'], result
        opener.assert_called_once_with('live', record, repo, name_timeout=0)
        sweeper.assert_called_once_with()

# Zero timeout makes one naming attempt without sleeping; later sync can retry.
with patch.object(herdr.space, 'run', return_value={'code': 'agent_not_found'} ) as get, \
     patch.object(herdr.time, 'sleep') as sleep:
    assert 'agentWarning' in herdr.name_agent('p', 'w', timeout=0)
    get.assert_called_once()
    sleep.assert_not_called()
with patch.object(herdr.space, 'run', return_value={'agent': {'name': 'w'}}), \
     patch.object(herdr.space, 'checked') as rename:
    assert herdr.name_agent('p', 'w', timeout=0) == {'agent': 'w'}
    rename.assert_not_called()
PY
printf 'herdr.test.sh: pass\n'
