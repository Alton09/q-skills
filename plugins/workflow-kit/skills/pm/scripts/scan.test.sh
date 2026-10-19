#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -x "$script_dir/scan.py" ]
export PYTHONDONTWRITEBYTECODE=1
python3 - "$script_dir" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))
import dossier
import scan

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    repo = root / 'repo'
    repo.mkdir()
    vault = root / 'vault'
    feature = vault / 'Features' / 'login'
    feature.mkdir(parents=True)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    fixture = root / 'sources.json'
    calls = root / 'calls'
    tool = bin_dir / 'fake'
    tool.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
data = json.loads(pathlib.Path(os.environ['SCAN_FIXTURE']).read_text())
with open(os.environ['SCAN_CALLS'], 'a') as stream:
    stream.write(json.dumps([name, *args]) + '\\n')
if name == 'gh': key = args[args.index('--state') + 1]
elif name == 'claude': key = 'sessions'
elif args[0] == 'worktree': key = 'worktrees'
elif args[0] == 'symbolic-ref': key = 'default'
else:
    assert args == ['branch', '--format=%(refname:short)', '--no-merged', data.get('expected_default', 'main')], args
    key = 'branches'
if key in data.get('fail', []):
    print('fixture failure: ' + key, file=sys.stderr)
    sys.exit(1)
value = data[key]
print(value if isinstance(value, str) else json.dumps(value))
''')
    tool.chmod(0o755)
    for name in ('git', 'gh', 'claude'):
        (bin_dir / name).symlink_to(tool)
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'],
               SCAN_FIXTURE=str(fixture), SCAN_CALLS=str(calls))
    wt = root / 'worktree'
    wt.mkdir()
    detached = root / 'detached'
    detached.mkdir()
    data = dict(
        open=[dict(number=123, title='Fix login crash', headRefName='fix-login', author={'login': 'alice'}, isDraft=True),
              dict(number=124, title='Tracked', headRefName='tracked', author={'login': 'bob'}, isDraft=False),
              dict(number=125, title='Solo PR', headRefName='solo', author=None, isDraft=False)],
        merged=[{'headRefName': 'squashed'}], closed=[{'headRefName': 'closed'}],
        default='origin/main',
        branches='main\nfix-login\ntracked\nsquashed\nclosed\nspike\nbranch-only\n',
        worktrees=f'worktree {repo}\nHEAD abc\nbranch refs/heads/main\n\nworktree {wt}\nHEAD abc\nbranch refs/heads/fix-login\n\nworktree {detached}\nHEAD abc\ndetached\n\n',
        sessions=[{'name': 'login-fix', 'cwd': str(wt / 'subdir'), 'state': 'running'},
                  {'name': 'login-retro-9', 'cwd': str(repo), 'state': 'running'},
                  {'name': 'project-retro-2', 'cwd': str(repo), 'state': 'running'},
                  {'name': 'finished', 'cwd': str(repo), 'state': 'done'},
                  {'name': 'manager', 'cwd': str(repo), 'state': 'running'},
                  {'name': 'manager2', 'cwd': str(repo), 'state': 'running'},
                  {'name': 'foreign', 'cwd': str(repo) + '-other', 'state': 'running'}])
    dossier.init_project(vault)
    dossier.item_new(feature, 'existing', 'Existing', ['pr=124'])
    # A sibling vault must never mark this vault's work as tracked.
    dossier.item_new(root / 'other-vault/Features/other', 'other', 'Other', ['pr=123'])
    (vault / 'Features/_project/ignored.md').write_text('# Ignored discovery keys\n\nbranch:spike\n')

    def command(action='scan', *extra, success=True):
        fixture.write_text(json.dumps(data))
        argv = [str(scripts / 'scan.py'), action, '--vault', str(vault)]
        if action != 'ignore':
            argv += ['--project-dir', str(repo)]
        if action in ('scan', 'adopt'):
            argv += ['--exclude-session', 'manager', '--exclude-session', 'manager2']
        result = subprocess.run([*argv, *extra], env=env, text=True, capture_output=True)
        assert result.returncode == (0 if success else 2), (argv, result.stdout, result.stderr)
        return json.loads(result.stdout)

    result = command()
    assert result['ok'] and not result['warnings'], result
    entries = {entry['key']: entry for entry in result['entries']}
    assert set(entries) == {'pr:123', 'pr:125', 'branch:branch-only', f'worktree:{detached}'}, entries
    pr = entries['pr:123']
    assert pr == dict(key='pr:123', title='Fix login crash', pr='123', branch='fix-login', worktree=str(wt),
                      session='login-fix', author='alice', draft=True), pr
    inbox = Path(result['inbox'])
    assert '- `pr:123` Fix login crash — branch `fix-login`, worktree `' + str(wt) + '`, session `login-fix`, author `alice`\n' in inbox.read_text()
    mtime = inbox.stat().st_mtime_ns
    assert command()['changed'] is False
    assert inbox.stat().st_mtime_ns == mtime
    log = [json.loads(line) for line in calls.read_text().splitlines()]
    assert ['gh', 'pr', 'list', '--state', 'merged', '--limit', '200', '--json', 'headRefName'] in log
    assert ['gh', 'pr', 'list', '--state', 'closed', '--limit', '200', '--json', 'headRefName'] in log

    # Every external source can fail independently and together, with exit zero.
    for failed in ('open', 'merged', 'closed', 'worktrees', 'default', 'branches', 'sessions'):
        data['fail'] = [failed]
        result = command()
        assert result['ok'] and any('fixture failure: ' + failed in w for w in result['warnings']), result
    data['fail'] = ['open', 'merged', 'closed', 'worktrees', 'default', 'branches', 'sessions']
    assert len(command()['warnings']) == 7
    data['fail'] = []
    sessions = data['sessions']
    data['sessions'] = [{'name': 'no-directory', 'state': 'running'}]
    assert any('no cwd field' in w for w in command()['warnings'])
    data['sessions'] = 'not JSON'
    assert any('invalid JSON' in w for w in command()['warnings'])
    data['sessions'] = sessions
    data['default'] = 'origin/develop'
    data['expected_default'] = 'develop'
    assert command()['ok']
    data['default'] = 'origin/main'
    data['expected_default'] = 'main'

    # Match branch, resolved worktree, and exact worker fields, including _project.
    tracked_path = vault / 'Features/_project/items/matched.md'
    for assignment in ('branch=fix-login', f'worktree={wt}/../worktree', 'worker=login-fix'):
        dossier.item_new(tracked_path.parent.parent, 'matched', 'Matched', [assignment])
        assert 'pr:123' not in {entry['key'] for entry in command()['entries']}
        tracked_path.unlink()

    # Root workers do not hide or merge independent root sessions.
    data['sessions'] += [{'name': 'tracked-root', 'cwd': str(repo)},
                         {'name': 'external-root', 'cwd': str(repo)},
                         {'name': 'external-root-2', 'cwd': str(repo)}]
    dossier.item_new(tracked_path.parent.parent, 'matched', 'Matched', ['worker=tracked-root'])
    entries = {entry['key']: entry for entry in command()['entries']}
    assert entries['session:external-root']['branch'] == '', entries
    assert 'session:external-root-2' in entries and 'session:tracked-root' not in entries
    tracked_path.unlink()
    data['sessions'] = sessions

    # Main-checkout sessions inherit a non-default branch and join its tracked PR.
    worktrees = data['worktrees']
    data['worktrees'] = worktrees.replace('branch refs/heads/main', 'branch refs/heads/tracked', 1)
    data['sessions'] = [{'name': 'root-feature', 'cwd': str(repo / 'src')}]
    entries = {entry['key']: entry for entry in command()['entries']}
    assert 'session:root-feature' not in entries and 'pr:124' not in entries, entries
    data['worktrees'] = worktrees
    data['sessions'] = sessions

    # PR tracking accepts URLs, # forms, and bare numbers.
    for value in ('https://github.com/owner/repo/pull/123', '#123', '123'):
        dossier.item_new(tracked_path.parent.parent, 'matched', 'Matched', ['pr=' + value])
        assert 'pr:123' not in {entry['key'] for entry in command()['entries']}
        tracked_path.unlink()

    # An ignored branch stays ignored after a PR gives it a higher-priority key.
    data['open'].append(dict(number=200, title='Spike PR', headRefName='spike'))
    assert 'pr:200' not in {entry['key'] for entry in command()['entries']}
    data['open'].pop()

    assert command('adopt', '--key', 'absent', '--feature', 'login', '--slug', 'absent', success=False)['ok'] is False
    assert command('adopt', '--key', 'pr:123', '--feature', 'missing', '--slug', 'absent', success=False)['ok'] is False
    adopted = command('adopt', '--key', 'pr:123', '--feature', 'login', '--slug', 'fix')
    item = adopted['item']
    assert item['stage'] == 'pr' and item['origin'] == 'external' and item['status'] == 'idle', item
    assert item['title'] == 'Fix login crash' and item['worker'] == 'login-fix' and item['worktree'] == str(wt), item
    assert '`pr:123`' not in inbox.read_text()
    assert 'manager' not in inbox.read_text(), inbox.read_text()
    dossier.project_board(vault)
    assert 'manager' not in (vault / 'Features/_project/board.md').read_text()
    adopted = command('adopt', '--key', 'pr:125', '--standalone', '--slug', 'solo')
    assert Path(adopted['file']).parent.parent.name == dossier.PROJECT_DIR
    assert dossier.feature_label(Path(adopted['file']).parent.parent.name) == 'project'
    assert adopted['item']['stage'] == 'pr' and adopted['item']['origin'] == 'external'
    adopted = command('adopt', '--key', 'branch:branch-only', '--feature', 'login', '--slug', 'branch', '--title', 'Custom')
    assert adopted['item']['stage'] == 'implement' and adopted['item']['title'] == 'Custom'
    # Branch-only default titles use the discovery key.
    data['branches'] += 'extra\n'
    adopted = command('adopt', '--key', 'branch:extra', '--standalone', '--slug', 'extra')
    assert adopted['item']['title'] == 'branch:extra'

    before = calls.read_text()
    ignored = command('ignore', '--key', f'worktree:{detached}')
    ignored_file = Path(ignored['ignored'])
    ignored_mtime = ignored_file.stat().st_mtime_ns
    command('ignore', '--key', f'worktree:{detached}')
    assert calls.read_text() == before, 'ignore must not run discovery'
    assert ignored_file.stat().st_mtime_ns == ignored_mtime
    assert ignored_file.read_text().splitlines().count(f'worktree:{detached}') == 1
    assert f'`worktree:{detached}`' not in inbox.read_text()
    # Remove manager sessions so all remaining activity is adopted or ignored.
    data['sessions'] = sessions[:4]
    result = command()
    assert result['entries'] == [], result
    assert inbox.read_text() == scan.INBOX_HEADER + '- (empty)\n'
    assert command()['changed'] is False

    # Missing executables and timeouts also pass through the single run boundary.
    assert scan.run(['/definitely/missing/tool'], repo)[0] is False
print('scan tests: pass')
PY
