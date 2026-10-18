#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mirror="$script_dir/herdr.py"
[ -x "$mirror" ]
"$mirror" --help >/dev/null
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" HERDR_ENV=1
export HERDR_TEST_STATE="$tmp/state.json" HERDR_TEST_LOG="$tmp/argv.jsonl"
mkdir -p "$HOME" "$tmp/bin" "$tmp/project/.claude" "$tmp/Features/alpha/items"
export PATH="$tmp/bin:$PATH"
item="$tmp/Features/alpha/items/one.md"
printf '%s\n' '---' 'title: Item one' 'stage: implement' 'status: paused' 'worker: alpha-one-ci' '---' >"$item"
printf '%s\n' '---' 'title: Item two' 'stage: implement' 'status: running' 'worker: alpha-two-comments' '---' >"$tmp/Features/alpha/items/two.md"

cat >"$tmp/bin/herdr" <<'PY'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with open(os.environ['HERDR_TEST_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\n')
if os.environ.get('HERDR_TEST_ERROR'):
    if os.environ['HERDR_TEST_ERROR'] == 'syntax':
        print('bad syntax', file=sys.stderr)
        sys.exit(2)
    print(json.dumps({'error': {'code': 'server_error', 'message': 'fake herdr failure'}}), file=sys.stderr)
    sys.exit(1)
path = Path(os.environ['HERDR_TEST_STATE'])
state = json.loads(path.read_text()) if path.exists() else {'workspaces': [], 'tabs': [], 'panes': [], 'next': 0}
def flag(name):
    return args[args.index(name) + 1]
result = {}
command = args[:2]
if command == ['workspace', 'list']:
    result = {'workspaces': state['workspaces']}
elif command in (['workspace', 'create'], ['tab', 'create']):
    state['next'] += 1
    number = state['next']
    ws = 'w1' if args[0] == 'workspace' else flag('--workspace')
    tab = {'workspace_id': ws, 'tab_id': f'{ws}:t{number}', 'label': '1' if args[0] == 'workspace' else flag('--label')}
    pane = {'pane_id': f'{ws}:p{number}', 'tab_id': tab['tab_id'], 'busy': False}
    if args[0] == 'workspace':
        state['workspaces'].append({'workspace_id': ws, 'label': flag('--label')})
        result['workspace'] = state['workspaces'][-1]
    state['tabs'].append(tab)
    state['panes'].append(pane)
    result.update(tab=tab, root_pane=pane)
elif command == ['tab', 'list']:
    result = {'tabs': [tab for tab in state['tabs'] if tab['workspace_id'] == flag('--workspace')]}
elif command == ['tab', 'rename']:
    next(tab for tab in state['tabs'] if tab['tab_id'] == args[2])['label'] = args[3]
elif command == ['pane', 'list']:
    result = {'panes': state['panes']}
elif command == ['pane', 'process-info']:
    pane = next(pane for pane in state['panes'] if pane['pane_id'] == flag('--pane'))
    result = {'process_info': {'shell_pid': 100, 'foreground_process_group_id': 200 if pane['busy'] else 100, 'foreground_processes': [{'pid':200, 'cmdline':pane.get('cmdline', 'claude attach old')}] if pane['busy'] else []}}
elif command == ['pane', 'send-keys']:
    assert args[3:] == ['ctrl+z'], args
    next(pane for pane in state['panes'] if pane['pane_id'] == args[2])['busy'] = False
elif command == ['pane', 'run']:
    assert args[3].startswith('command claude attach '), args
    pane = next(pane for pane in state['panes'] if pane['pane_id'] == args[2])
    pane.update(busy=True, cmdline=args[3])
elif command == ['agent', 'get']:
    pane = next(pane for pane in state['panes'] if pane['pane_id'] == args[2])
    result = {'agent': {'agent': 'claude', 'pane_id': args[2], 'name':pane.get('name')}}
elif command == ['agent', 'rename']:
    next(pane for pane in state['panes'] if pane['pane_id'] == args[2])['name'] = args[3]
    result = {'agent': {'name': args[3]}}
elif command == ['tab', 'close']:
    state['tabs'] = [tab for tab in state['tabs'] if tab['tab_id'] != args[2]]
    if not state['tabs'] and not os.environ.get('HERDR_TEST_KEEP_EMPTY'):
        state['workspaces'] = []
elif command == ['workspace', 'close']:
    assert not any(tab['workspace_id'] == args[2] for tab in state['tabs']), state
    state['workspaces'] = [ws for ws in state['workspaces'] if ws['workspace_id'] != args[2]]
else:
    raise AssertionError(args)
path.write_text(json.dumps(state))
if command != ['pane', 'run']:
    print(json.dumps({'id': 'fake', 'result': result}))
PY
chmod +x "$tmp/bin/herdr"
check() { python3 -c "import json,sys; $1"; }
run() { "$mirror" "$@"; }

# Every command skips before item reads or herdr calls outside herdr.
for action in available prepare attach ensure close; do
  arguments=("$action")
  case "$action" in
    prepare|ensure) arguments+=(--item missing --repo "$tmp/project") ;;
    attach) arguments+=(--item missing --pane absent) ;;
    close) arguments+=(--item missing) ;;
  esac
  env -u HERDR_ENV "$mirror" "${arguments[@]}" | check 'x=json.load(sys.stdin); assert x["skipped"] is True, x'
done
[ ! -e "$HERDR_TEST_LOG" ]

# Project and user configuration can disable every action without invoking herdr.
printf '%s\n' '{"lead":{"herdr":false}}' >"$tmp/project/.claude/workflow-kit.json"
for action in available prepare attach ensure close; do
  arguments=("$action" --project-dir "$tmp/project")
  case "$action" in
    prepare|ensure) arguments+=(--item missing --repo "$tmp/project") ;;
    attach) arguments+=(--item missing --pane absent) ;;
    close) arguments+=(--item missing) ;;
  esac
  run "${arguments[@]}" | check 'x=json.load(sys.stdin); assert x["skipped"] and "disabled" in x["reason"], x'
done
[ ! -e "$HERDR_TEST_LOG" ]
printf '%s\n' '{}' >"$tmp/project/.claude/workflow-kit.json"
run available --project-dir "$tmp/project" | check 'x=json.load(sys.stdin); assert x == {"available":True,"reason":None}, x'

# Invalid config warnings survive both availability outcomes.
printf '%s\n' '{"lead":{"herdr":"false"}}' >"$tmp/project/.claude/workflow-kit.json"
run available --project-dir "$tmp/project" | check 'x=json.load(sys.stdin); assert x["available"] and x["warnings"] == ["lead.herdr must be a boolean; using true"], x'
env -u HERDR_ENV "$mirror" available --project-dir "$tmp/project" | check 'x=json.load(sys.stdin); assert not x["available"] and x["warnings"] == ["lead.herdr must be a boolean; using true"], x'
printf '%s\n' '{}' >"$tmp/project/.claude/workflow-kit.json"

# First worker uses the root tab; reuse looks up its pane separately.
ls -aR "$tmp/Features/alpha" >"$tmp/feature-before"
run prepare --item "$item" --repo "$tmp/project" | check 'x=json.load(sys.stdin); assert x == {"workspace":"w1","tab":"w1:t1","pane":"w1:p1","created":True}, x'
run prepare --item "$item" --repo "$tmp/project" | check 'x=json.load(sys.stdin); assert not x["created"] and x["pane"] == "w1:p1", x'
run attach --item "$item" --pane w1:p1 | check 'x=json.load(sys.stdin); assert x["attached"] and x["agent"] == "alpha-one-ci", x'
run prepare --item "$item" --repo "$tmp/project" | check 'x=json.load(sys.stdin); assert not x["created"], x'

# Reconcile twice creates and attaches once, using a new tab in the existing workspace.
second="$tmp/Features/alpha/items/two.md"
run ensure --item "$second" --repo "$tmp/project" | check 'x=json.load(sys.stdin); assert x["created"] and x["ensured"], x'
run ensure --item "$second" --repo "$tmp/project" | check 'x=json.load(sys.stdin); assert x == {"ensured":False}, x'
python3 - "$HERDR_TEST_LOG" "$tmp/project" <<'PY'
import json
import sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert sum(call[:2] == ['workspace', 'create'] for call in calls) == 1, calls
assert sum(call[:2] == ['tab', 'create'] for call in calls) == 1, calls
assert sum(call[:2] == ['pane', 'run'] for call in calls) == 2, calls
assert ['tab', 'rename', 'w1:t1', 'Item one'] in calls
assert ['pane', 'send-keys', 'w1:p1', 'ctrl+z'] in calls
for call in calls:
    if call[:2] in (['workspace', 'create'], ['tab', 'create']):
        assert call[call.index('--cwd') + 1] == sys.argv[2] and '--no-focus' in call, call
    assert 'ctrl+c' not in call, call
PY

# Errors (JSON and syntax) remain one warning object and exit zero.
HERDR_TEST_ERROR=server run prepare --item "$item" --repo "$tmp/project" | check 'x=json.load(sys.stdin); assert x["warning"] == "fake herdr failure", x'
HERDR_TEST_ERROR=syntax run close --item "$item" | check 'x=json.load(sys.stdin); assert "warning" in x, x'

# Closing an owned tab preserves other tabs, even when their label is unrelated.
python3 - "$HERDR_TEST_STATE" <<'PY'
import json
import sys
path = sys.argv[1]
state = json.load(open(path))
state['tabs'].append({'workspace_id':'w1', 'tab_id':'w1:foreign', 'label':'Personal shell'})
state['panes'].append({'pane_id':'w1:foreign', 'tab_id':'w1:foreign', 'busy':False})
open(path, 'w').write(json.dumps(state))
PY
run close --item "$item" | check 'x=json.load(sys.stdin); assert x["closed"], x'
run close --item "$second" | check 'x=json.load(sys.stdin); assert x["closed"], x'
python3 - "$HERDR_TEST_STATE" "$HERDR_TEST_LOG" <<'PY'
import json
import sys
state = json.load(open(sys.argv[1]))
assert state['workspaces'] and [tab['label'] for tab in state['tabs']] == ['Personal shell'], state
assert not any(json.loads(line)[:2] == ['workspace', 'close'] for line in open(sys.argv[2]))
PY
# Prepare/close must never add state files to the feature directory.
ls -aR "$tmp/Features/alpha" >"$tmp/feature-after"
cmp "$tmp/feature-before" "$tmp/feature-after"

# Adopting an existing workspace creates a tab without renaming the user's root tab.
run prepare --item "$item" --repo "$tmp/project" | check 'x=json.load(sys.stdin); assert x["created"], x'
python3 - "$HERDR_TEST_STATE" "$HERDR_TEST_LOG" <<'PY'
import json
import sys
state = json.load(open(sys.argv[1]))
assert [tab['label'] for tab in state['tabs']] == ['Personal shell', 'Item one'], state
calls = [json.loads(line) for line in open(sys.argv[2])]
assert sum(call[:2] == ['tab', 'rename'] for call in calls) == 1, calls
PY
run close --item "$item" | check 'x=json.load(sys.stdin); assert x["closed"], x'

# A matching item title establishes ownership without any prior prepare call.
printf '%s\n' '---' 'title: Personal shell' 'stage: implement' 'status: paused' '---' >"$tmp/Features/alpha/items/foreign.md"
run close --item "$tmp/Features/alpha/items/foreign.md" | check 'x=json.load(sys.stdin); assert x["closed"], x'

# The last owned tab closes its workspace automatically; cleanup is repeatable.
python3 - "$HERDR_TEST_STATE" <<'PY'
import json
import sys
path = sys.argv[1]
state = json.load(open(path))
state['tabs'] = []
state['workspaces'] = []
open(path, 'w').write(json.dumps(state))
PY
run prepare --item "$item" --repo "$tmp/project" | check 'x=json.load(sys.stdin); assert x["created"], x'
run close --item "$item" | check 'x=json.load(sys.stdin); assert x["closed"], x'
run close --item "$item" | check 'x=json.load(sys.stdin); assert not x["closed"], x'
python3 - "$HERDR_TEST_STATE" <<'PY'
import json
import sys
assert json.load(open(sys.argv[1]))['workspaces'] == []
PY

# Close an empty workspace explicitly if herdr leaves it behind.
run prepare --item "$item" --repo "$tmp/project" | check 'x=json.load(sys.stdin); assert x["created"], x'
HERDR_TEST_KEEP_EMPTY=1 run close --item "$item" | check 'x=json.load(sys.stdin); assert x["closed"], x'
python3 - "$HERDR_TEST_STATE" "$HERDR_TEST_LOG" <<'PY'
import json
import sys
assert json.load(open(sys.argv[1]))['workspaces'] == []
assert ['workspace', 'close', 'w1'] in [json.loads(line) for line in open(sys.argv[2])]
PY

python3 - "$script_dir" <<'PY'
import re
import sys
from unittest.mock import patch
sys.path.insert(0, sys.argv[1])
import herdr

for worker in ('', '123', '-abc', 'A B.C!', 'Ünicode', 'x' * 300, 'a-' + 'b' * 100, 'x' * 80 + '-ci', 'x' * 80 + '-comments'):
    assert re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', herdr.agent_name(worker)), worker
ci = herdr.agent_name('x' * 80 + '-ci')
comments = herdr.agent_name('x' * 80 + '-comments')
assert len(ci) == len(comments) == 32 and ci.endswith('-ci') and comments.endswith('-comments') and ci != comments
long_workers = ['tl-herdr-check-scratch-file-edit-plan', 'tl-herdr-check-scratch-file-other-plan']
names = [herdr.agent_name(worker) for worker in long_workers]
assert names[0] != names[1] and all(name.endswith('-plan') and len(name) == 32 for name in names), names
assert names == [herdr.agent_name(worker) for worker in long_workers]
assert herdr.agent_name('alpha-one-ci') == 'alpha-one-ci'
with patch.object(herdr.shutil, 'which', return_value=None):
    assert not herdr.available(herdr.Path('.'))['available']
# Detection may lag behind pane run; rename follows the successful poll.
responses = [{}, {'warning':'not detected', 'code':'agent_not_found'}, {'agent':{'agent':'claude'}}, {}]
with patch.object(herdr, 'run_herdr', side_effect=responses) as run, patch.object(herdr.launch, 'read_item', return_value={'worker':"a'; echo unsafe"}), patch.object(herdr.time, 'sleep'):
    herdr.attach(herdr.Path('unused'), 'p1')
    assert run.call_args_list[0].args[0][3] == "command claude attach 'a'\"'\"'; echo unsafe'"
    assert run.call_args_list[-1].args[0][:3] == ['agent', 'rename', 'p1']
# Detection after the old three-second deadline still renames; timeout is injectable.
responses = [{}, {}, {'agent':{'agent':'claude'}}, {}]
with patch.object(herdr, 'run_herdr', side_effect=responses) as run, patch.object(herdr.launch, 'read_item', return_value={'worker':'alpha-one-ci'}), patch.object(herdr.time, 'sleep'), patch.object(herdr.time, 'monotonic', side_effect=[0, 4]):
    assert herdr.attach(herdr.Path('unused'), 'p1')['attached']
    assert run.call_args_list[-1].args[0] == ['agent', 'rename', 'p1', 'alpha-one-ci']
with patch.object(herdr, 'ATTACH_TIMEOUT', 0), patch.object(herdr, 'run_herdr', return_value={}), patch.object(herdr.launch, 'read_item', return_value={'worker':'alpha-one-ci'}):
    try:
        herdr.attach(herdr.Path('unused'), 'p1')
    except herdr.MirrorError as exc:
        assert 'timed out' in str(exc)
    else:
        raise AssertionError('expected detection timeout')
# Existing tabs repair a cleared or stale name without replacing the attach.
for name in (None, 'old-worker', 'alpha-one-ci'):
    info = {'shell_pid':100, 'foreground_process_group_id':200, 'foreground_processes':[{'pid':200, 'cmdline':'node /npm/bin/claude attach alpha-one-ci'}]}
    with patch.object(herdr, 'process_info', return_value=info), patch.object(herdr.launch, 'read_item', return_value={'title':'Item one', 'worker':'alpha-one-ci'}), patch.object(herdr, 'workspace', return_value='w1'), patch.object(herdr, 'tabs', return_value=[{'tab_id':'t1', 'label':'Item one'}]), patch.object(herdr, 'checked', return_value={'panes':[{'pane_id':'p1', 'tab_id':'t1'}]}) as checked, patch.object(herdr, 'run_herdr', return_value={'agent':{'name':name}}):
        assert herdr.ensure(herdr.Path('unused'), herdr.Path('.')) == {'ensured':name != 'alpha-one-ci'}
        assert (['agent', 'rename', 'p1', 'alpha-one-ci'] in [call.args[0] for call in checked.call_args_list]) == (name != 'alpha-one-ci')
# A stale worker or exited attach is rebuilt in the existing pane.
for command in ('claude attach alpha-one', 'node /npm/bin/claude attach alpha-one', None):
    info = {'shell_pid':100, 'foreground_process_group_id':200 if command else 100, 'foreground_processes':[{'pid':200, 'cmdline':command}] if command else []}
    free = {'shell_pid':100, 'foreground_process_group_id':100}
    with patch.object(herdr.launch, 'read_item', return_value={'title':'Item one', 'worker':'alpha-one-ci'}), patch.object(herdr, 'workspace', return_value='w1'), patch.object(herdr, 'tabs', return_value=[{'tab_id':'t1', 'label':'Item one'}]), patch.object(herdr, 'checked', return_value={'panes':[{'pane_id':'p1', 'tab_id':'t1'}]}) as checked, patch.object(herdr, 'process_info', return_value=info), patch.object(herdr, 'wait_for_shell', return_value=free), patch.object(herdr, 'attach') as attach:
        assert herdr.ensure(herdr.Path('unused'), herdr.Path('.')) == {'ensured':True}
        attach.assert_called_once_with(herdr.Path('unused'), 'p1')
        assert not any(call.args[0][:2] == ['agent', 'rename'] for call in checked.call_args_list)
        assert (['pane', 'send-keys', 'p1', 'ctrl+z'] in [call.args[0] for call in checked.call_args_list]) == bool(command)
# Native, node, and bun clients share the same subcommand gate.
for command in ('claude attach old', 'node /npm/bin/claude attach old', 'bun /npm/cli.js agents'):
    assert herdr.claude_client({'cmdline':command}, ('attach', 'agents'))
for command in ('node other.js attach old', 'cli.js attach old', 'claude --bg old'):
    assert not herdr.claude_client({'cmdline':command}, ('attach', 'agents'))
# Signals target only attach/agents clients, including a stopped process.
for state, expected in [('S', herdr.signal.SIGTERM), ('T', herdr.signal.SIGKILL)]:
    busy = {'shell_pid':100, 'foreground_process_group_id':200, 'foreground_processes':[{'pid':200, 'cmdline':'node /npm/bin/claude attach old'}]}
    free = {'shell_pid':100, 'foreground_process_group_id':100}
    with patch.object(herdr, 'process_info', return_value=busy), patch.object(herdr, 'wait_for_shell', side_effect=[busy, free]), patch.object(herdr, 'checked'), patch.object(herdr.Path, 'read_text', return_value=f'200 (claude) {state} 100'), patch.object(herdr.os, 'kill') as kill:
        herdr.free_pane('p1')
        kill.assert_called_once_with(200, expected)
# Foreign foreground processes get no keys, signals, or tab close; CLI returns warning/0.
busy = {'shell_pid':100, 'foreground_process_group_id':200, 'foreground_processes':[{'pid':200, 'cmdline':'vim notes.md'}]}
with patch.object(herdr, 'available', return_value={'available':True}), patch.object(herdr.launch, 'read_item', return_value={'title':'Item one', 'worker':'alpha-one-ci'}), patch.object(herdr, 'workspace', return_value='w1'), patch.object(herdr, 'tabs', return_value=[{'tab_id':'t1', 'label':'Item one'}]), patch.object(herdr, 'checked', return_value={'panes':[{'pane_id':'p1', 'tab_id':'t1'}]}) as checked, patch.object(herdr, 'process_info', return_value=busy), patch.object(herdr.os, 'kill') as kill:
    import contextlib
    import io
    import json
    for action in ('prepare', 'ensure', 'close'):
        output = io.StringIO()
        args = [action, '--item', 'unused'] + (['--repo', '.'] if action in ('prepare', 'ensure') else [])
        with contextlib.redirect_stdout(output):
            assert herdr.main(args) == 0
        assert 'another process' in json.loads(output.getvalue())['warning']
    assert all(call.args[0][:2] == ['pane', 'list'] for call in checked.call_args_list)
    kill.assert_not_called()
# Unexpected JSON row shapes stay warning/0.
with patch.object(herdr, 'available', return_value={'available':True}), patch.object(herdr.launch, 'read_item', return_value={'title':'Item one'}), patch.object(herdr, 'checked', return_value={'workspaces':[None]}), contextlib.redirect_stdout(io.StringIO()) as output:
    assert herdr.main(['prepare', '--item', 'unused', '--repo', '.']) == 0
    assert 'warning' in json.loads(output.getvalue())
# Malformed row shapes also keep the runtime warning contract.
for exc in (IndexError('bad row'), AttributeError('bad row')):
    with patch.object(herdr, 'available', side_effect=exc), contextlib.redirect_stdout(io.StringIO()) as output:
        assert herdr.main(['available']) == 0
        assert json.loads(output.getvalue()) == {'warning':'bad row'}
PY

# Usage errors write stderr and exit 2, with no success JSON.
printf '%s\n' '---' 'not valid frontmatter' '---' >"$tmp/Features/alpha/items/bad.md"
printf '%s\n' '---' 'title: No worker' 'stage: implement' '---' >"$tmp/Features/alpha/items/no-worker.md"
for bad_item in bad no-worker missing; do
  rc=0
  run attach --item "$tmp/Features/alpha/items/$bad_item.md" --pane w1:p1 >"$tmp/bad.out" 2>"$tmp/bad.err" || rc=$?
  [ "$rc" -eq 2 ]
  [ ! -s "$tmp/bad.out" ]
  case "$bad_item" in
    bad) expected='invalid frontmatter line' ;;
    no-worker) expected='attach requires item worker' ;;
    missing) expected='No such file or directory' ;;
  esac
  rg -q "$expected" "$tmp/bad.err"
done
printf 'herdr.test.sh: pass\n'
