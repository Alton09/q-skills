#!/usr/bin/env bash
# Tests for herdr_space.py against a fake herdr CLI. Hermetic: HOME, PATH, and state live
# in a mktemp dir. Exits non-zero on the first failure.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
space="$here/herdr_space.py"
[ -x "$space" ]
"$space" --help >/dev/null
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export HERDR_TEST_STATE="$tmp/state.json" HERDR_TEST_LOG="$tmp/argv.jsonl"
mkdir -p "$HOME" "$tmp/bin" "$tmp/project/.claude" "$tmp/wt"
export PATH="$tmp/bin:$PATH"
unset HERDR_ENV WORKFLOW_KIT_HERDR HERDR_WORKSPACE_ID

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
chmod +x "$tmp/bin/herdr"
check() { python3 -c "import json,sys; $1"; }
run() { "$space" "$@"; }

# Outside herdr every action is a silent skip with no herdr call.
for action in available open close mirror sweep; do
  case "$action" in
    open) a=(open --label codex:x --cwd "$tmp/wt" --command true) ;;
    close) a=(close --label codex:x) ;;
    mirror) a=(mirror --label codex:x --pid 1 --file f --format codex) ;;
    *) a=("$action") ;;
  esac
  run "${a[@]}" --project-dir "$tmp/project" | check 'x=json.load(sys.stdin); assert x.get("skipped") or x.get("available") is False, x'
done
[ ! -e "$HERDR_TEST_LOG" ]

# HERDR_ENV=1 (inside herdr) or WORKFLOW_KIT_HERDR=1 (a pm worker) turns spaces on.
HERDR_ENV=1 run available --project-dir "$tmp/project" | check 'x=json.load(sys.stdin); assert x["available"], x'
HERDR_ENV=0 WORKFLOW_KIT_HERDR=1 run available --project-dir "$tmp/project" | check 'x=json.load(sys.stdin); assert x["available"], x'
export WORKFLOW_KIT_HERDR=1

# pm.herdr: false disables spaces; a bad config disables them without failing the caller.
printf '%s\n' '{"pm":{"herdr":false}}' >"$tmp/project/.claude/workflow-kit.json"
run mirror --label codex:x --pid 1 --file f --format codex --project-dir "$tmp/project" | check 'x=json.load(sys.stdin); assert x["skipped"] and "disabled" in x["reason"], x'
printf '%s\n' '{"pm":{"herdr":"no"}}' >"$tmp/project/.claude/workflow-kit.json"
run available --project-dir "$tmp/project" | check 'x=json.load(sys.stdin); assert not x["available"] and x["reason"].startswith("config"), x'
printf '%s\n' '{}' >"$tmp/project/.claude/workflow-kit.json"
[ ! -e "$HERDR_TEST_LOG" ]
cd "$tmp/project"

# mirror opens one workspace per executor worker, in the worktree, running the viewer.
run mirror --label codex:wt/phase-1 --pid 4242 --file "$tmp/wt/p1.jsonl" --err "$tmp/wt/p1.err" --format codex --cwd "$tmp/wt" \
  | check 'x=json.load(sys.stdin); assert x["opened"] and x["workspace"] == "w1" and x["pane"] == "w1:p1", x'
python3 - "$HERDR_TEST_STATE" "$tmp/wt" <<'PY'
import json, shlex, sys
state = json.load(open(sys.argv[1]))
assert [w['label'] for w in state['workspaces']] == ['codex:wt/phase-1'], state
pane = state['panes'][0]
assert pane['cwd'] == sys.argv[2], pane
argv = shlex.split(pane['fg'])
assert argv[1].endswith('herdr_space.py') and argv[2] == 'view', argv
assert argv[argv.index('--pid') + 1] == '4242' and argv[argv.index('--label') + 1] == 'codex:wt/phase-1', argv
assert argv[argv.index('--file') + 1] == sys.argv[2] + '/p1.jsonl' and argv[argv.index('--format') + 1] == 'codex', argv
PY

# A retry with the same label replaces the old space instead of stacking a second one.
run mirror --label codex:wt/phase-1 --pid 4343 --file "$tmp/wt/p1.jsonl" --format codex --cwd "$tmp/wt" | check 'x=json.load(sys.stdin); assert x["workspace"] == "w2", x'
python3 -c 'import json,sys; assert [w["workspace_id"] for w in json.load(open(sys.argv[1]))["workspaces"]] == ["w2"]' "$HERDR_TEST_STATE"

# Only executor prefixes are valid mirror labels.
run mirror --label mine --pid 1 --file f --format pi | check 'x=json.load(sys.stdin); assert "executor space labels" in x["warning"], x'

# Post-wait close leaves a live viewer to drain output and close itself.
run close --if-idle --label codex:wt/phase-1 | check 'x=json.load(sys.stdin); assert x == {"closed": [], "kept": ["w2"]}, x'
# close removes the labelled space; a user process in the pane keeps it open with a warning.
run close --label codex:wt/phase-1 | check 'x=json.load(sys.stdin); assert x == {"closed": ["w2"]}, x'
run open --label pi:wt/phase-2 --cwd "$tmp/wt" --command 'vim notes.md' | check 'x=json.load(sys.stdin); assert x["opened"], x'
run close --label pi:wt/phase-2 | check 'x=json.load(sys.stdin); assert x["closed"] == [] and "did not start" in x["warning"], x'

# sweep closes executor spaces back at their shell and keeps running viewers and other spaces.
python3 - "$HERDR_TEST_STATE" <<'PY'
import json, sys
path = sys.argv[1]
state = json.load(open(path))
state['workspaces'] += [{'workspace_id': 'wa', 'label': 'codex:wt/done'}, {'workspace_id': 'wb', 'label': 'pi:wt/live'}, {'workspace_id': 'wc', 'label': 'Personal'}]
state['panes'] += [
    {'pane_id': 'wa:p1', 'workspace_id': 'wa', 'cwd': '/x', 'fg': None},
    {'pane_id': 'wb:p1', 'workspace_id': 'wb', 'cwd': '/x', 'fg': 'python3 /s/herdr_space.py view --pid 9'},
    {'pane_id': 'wc:p1', 'workspace_id': 'wc', 'cwd': '/x', 'fg': None},
]
open(path, 'w').write(json.dumps(state))
PY
run close --if-idle --label codex:wt/done | check 'x=json.load(sys.stdin); assert x == {"closed": ["wa"]}, x'
# Restore an idle executor to exercise sweep too.
run open --label codex:wt/done --cwd "$tmp/wt" --command true >/dev/null
python3 - "$HERDR_TEST_STATE" <<'PYIDLE'
import json, sys
p = sys.argv[1]; s = json.load(open(p)); s["workspaces"][-1]["workspace_id"] = "wa"; s["panes"][-1].update(workspace_id="wa", fg=None); open(p, "w").write(json.dumps(s))
PYIDLE
run sweep | check 'x=json.load(sys.stdin); assert x == {"closed": ["wa"]}, x'

# herdr failures are one warning object with exit 0.
HERDR_TEST_ERROR=1 run mirror --label codex:x --pid 1 --file f --format codex | check 'x=json.load(sys.stdin); assert x["warning"] == "fake herdr failure", x'

# Renderers, the follow loop, and view's self-close.
python3 - "$here" "$tmp" <<'PY'
import io, json, os, subprocess, sys, time
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0, sys.argv[1])
import herdr_space as hs
tmp = Path(sys.argv[2])
strip = lambda lines: [l.replace(hs.DIM, '').replace(hs.BOLD, '').replace(hs.RED, '').replace(hs.RESET, '') for l in lines]

# A sweep between create and pane run cannot see the initializing executor label.
original_checked = hs.checked
interleaved = []
def during_create(argv):
    result = original_checked(argv)
    if argv[:2] == ["workspace", "create"]:
        assert argv[argv.index("--label") + 1] == "starting:codex:race"
        interleaved.append(hs.sweep())
    return result
with patch.object(hs, "checked", side_effect=during_create):
    opened = hs.open_space("codex:race", tmp, "python3 /s/herdr_space.py view --pid 9")
assert interleaved == [{"closed": []}], interleaved
assert hs.spaces("codex:race")[0]["workspace_id"] == opened["workspace"]
# Failed pane startup or label publication attempts cleanup, still reporting the error.
for failed in (["pane", "run"], ["workspace", "rename"]):
    def fail(argv):
        if argv[:2] == failed:
            raise hs.SpaceError("startup failed")
        return original_checked(argv)
    with patch.object(hs, "checked", side_effect=fail):
        try:
            hs.open_space("codex:broken", tmp, "python3 /s/herdr_space.py view --pid 9")
        except hs.SpaceError as exc:
            assert str(exc) == "startup failed"
        else:
            raise AssertionError("expected startup warning")
    assert not hs.spaces("starting:codex:broken")

codex = [
    {"type": "thread.started", "thread_id": "t-1"},
    {"type": "item.started", "item": {"type": "command_execution", "command": "ls"}},
    {"type": "item.completed", "item": {"type": "command_execution", "command": "ls", "aggregated_output": "a\nb\nc\nd\ne\n", "exit_code": 2}},
    {"type": "item.completed", "item": {"type": "file_change", "changes": [{"path": "/w/b.txt", "kind": "add"}]}},
    {"type": "item.started", "item": {"type": "file_change", "changes": [{"path": "/w/b.txt", "kind": "add"}]}},
    {"type": "item.completed", "item": {"type": "agent_message", "text": "ok"}},
    {"type": "turn.completed", "usage": {"input_tokens": 10, "cached_input_tokens": 4, "output_tokens": 3}},
    {"type": "turn.failed", "error": {"message": "boom"}},
]
out = strip([l for e in codex for l in hs.render_codex(e)])
assert out == ["codex thread t-1", "$ ls", "  b", "  c", "  d", "  e", "  exit 2", "~ add /w/b.txt", "ok",
               "turn done: in 10 (cached 4) out 3", "error: boom"], out

pi = [
    {"type": "message_end", "message": {"role": "user", "content": [{"type": "text", "text": "hidden"}]}},
    {"type": "message_end", "message": {"role": "assistant", "content": [
        {"type": "thinking", "thinking": "hmm"}, {"type": "text", "text": "running"},
        {"type": "toolCall", "name": "bash", "arguments": {"command": "ls"}}]}},
    {"type": "tool_execution_end", "isError": True, "result": {"content": [{"type": "text", "text": "no such file"}]}},
    {"type": "message_end", "message": {"role": "assistant", "content": [], "errorMessage": "401: key expired"}},
    {"type": "agent_end"},
]
out = strip([l for e in pi for l in hs.render_pi(e)])
assert out == ["· hmm", "running", '→ bash {"command": "ls"}', "  no such file", "error: 401: key expired", "agent finished"], out
assert hs.render_line("not json", "codex") == ["not json"] and hs.render_line("[1]", "pi") == []

# follow prints every event a live writer appends, including a final unterminated line.
stream = tmp / "live.jsonl"
writer = subprocess.Popen([sys.executable, "-c", (
    "import json,sys,time\n"
    "f=open(sys.argv[1],'w')\n"
    "for t in ('one','two'):\n"
    "    f.write(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':t}})+'\\n'); f.flush(); time.sleep(0.3)\n"
    "f.write(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':'three'}})); f.flush()\n"), str(stream)])
buffer = io.StringIO()
with patch.object(hs, "FOLLOW_INTERVAL", 0.05):
    hs.follow(writer.pid, stream, "codex", out=buffer)
writer.wait()
assert buffer.getvalue().split() == ["one", "two", "three"], buffer.getvalue()

# view closes only its own workspace, and only when the label matches.
calls = []
def fake_run(argv):
    calls.append(argv)
    return {"workspaces": [{"workspace_id": "w9", "label": "codex:wt/p"}]} if argv[:2] == ["workspace", "list"] else {}
dead = subprocess.Popen(["true"]); dead.wait()
for label, closes in (("codex:wt/p", True), ("codex:wt/other", False)):
    calls.clear()
    args = hs.parser().parse_args(["view", "--pid", str(dead.pid), "--file", str(tmp / "none.jsonl"), "--format", "codex", "--label", label])
    with patch.object(hs, "run", side_effect=fake_run), patch.object(hs, "CLOSE_DELAY", 0), patch.dict(os.environ, {"HERDR_WORKSPACE_ID": "w9"}), patch("sys.stdout", io.StringIO()):
        assert hs.view(args) == 0
    assert (["workspace", "close", "w9"] in calls) == closes, calls

# own_process recognises viewers and claude attach/agents clients only.
for cmdline, ours in (("python3 /s/herdr_space.py view --pid 1", True), ("command claude attach abc", True),
                      ("node /npm/bin/claude attach abc", True), ("bun /npm/cli.js agents", True),
                      ("vim notes.md", False), ("claude --bg x", False), ("node other.js attach", False)):
    assert hs.own_process({"cmdline": cmdline}) == ours, cmdline
PY

printf 'herdr_space.test.sh: pass\n'
