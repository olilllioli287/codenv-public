#!/bin/bash
# 離線、可重跑：release 使用暫存 repo 與 push/gh 替身；執行器使用隔離看板與假 agy。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT" <<'PY'
import collections
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
real_git = shutil.which('git')
processes = []

def check(ok, message):
    if not ok:
        raise AssertionError(message)

def run(args, **kw):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, **kw).stdout

def executable(path, source):
    path.write_text(source)
    path.chmod(0o755)

def until(predicate, description, timeout=12):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.03)
    raise AssertionError('等待逾時：' + description)

with tempfile.TemporaryDirectory(prefix='codenv-test-resume-') as temp:
    base = Path(temp)
    env = dict(os.environ)
    # 不沿用開發者的 git 設定、HOME、真實看板或桌寵。
    for key in list(env):
        if key.startswith(('GIT_', 'CODENV_')):
            del env[key]
    home = base / 'home'
    home.mkdir()
    env.update(HOME=str(home), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
               GIT_TERMINAL_PROMPT='0', PYTHONDONTWRITEBYTECODE='1')
    repo, remote, fakebin = (base / name for name in ('repo', 'remote.git', 'bin'))
    fakebin.mkdir()
    run([real_git, 'init', '-q', '--bare', str(remote)], env=env)
    run([real_git, 'init', '-q', '-b', 'main', str(repo)], env=env)
    def git(*args):
        return run([real_git, '-C', str(repo), *args], env=env)
    git('config', 'user.name', '離線測試')
    git('config', 'user.email', 'test@example.invalid')
    git('config', 'commit.gpgsign', 'false')
    git('config', 'tag.gpgsign', 'false')
    git('remote', 'add', 'origin', str(remote))
    shutil.copyfile(root / 'release.sh', repo / 'release.sh')
    with (repo / 'Info.plist').open('wb') as f:
        plistlib.dump({'CFBundleShortVersionString': '00.00.00', 'CFBundleVersion': '00.00.00'}, f)
    git('add', 'release.sh', 'Info.plist')
    git('commit', '-qm', '測試初始版本')
    (repo / 'dist').mkdir()
    for version in ('00.00.01', '00.00.02', '00.00.03', '00.00.04'):
        (repo / 'dist' / f'codenv-{version}.dmg').write_text('假的 DMG\n')
    state = base / 'gh-state'
    state.mkdir()
    pushlog, ghlog = base / 'push.log', base / 'gh.log'
    pushlog.touch()
    ghlog.touch()
    # 真正的 git push 絕不執行：以 bare repo 從本機抓取 ref 模擬推送結果。
    executable(fakebin / 'git', f'''#!/bin/bash
set -eu
if [ "$1" = push ]; then
    shift
    [ "$1" = -q ] && shift
    [ "$1" = origin ] || exit 90
    shift
    for ref in "$@"; do
        echo "$ref" >> {shlex.quote(str(pushlog))}
        if [ "$ref" = HEAD ]; then
            spec=HEAD:refs/heads/main
        else
            spec="refs/tags/$ref:refs/tags/$ref"
        fi
        {shlex.quote(real_git)} --git-dir={shlex.quote(str(remote))} fetch -q {shlex.quote(str(repo))} "$spec"
    done
    exit 0
fi
exec {shlex.quote(real_git)} "$@"
''')
    executable(fakebin / 'gh', f'''#!/bin/bash
set -eu
[ "$1" = release ] || exit 91
cmd="$2"; tag="$3"
state={shlex.quote(str(state))}
printf '%s %s\\n' "$cmd" "$tag" >> {shlex.quote(str(ghlog))}
case "$cmd" in
    view)
        [ -f "$state/$tag.release" ] || exit 1
        cat "$state/$tag.assets"
        ;;
    create)
        if [ -f "$state/fail-before" ]; then rm "$state/fail-before"; exit 1; fi
        [ ! -f "$state/$tag.release" ] || exit 92
        touch "$state/$tag.release"
        basename "$4" > "$state/$tag.assets"
        echo "created $tag" >> {shlex.quote(str(ghlog))}
        if [ -f "$state/fail-after" ]; then rm "$state/fail-after"; exit 1; fi
        ;;
    upload)
        [ "$7" = --clobber ] || exit 93
        basename "$4" >> "$state/$tag.assets"
        ;;
    *) exit 94 ;;
esac
''')
    release_env = dict(env, PATH=str(fakebin) + ':' + env['PATH'],
                       CODENV_RELEASE_SKIP_BUILD='1', CODENV_RELEASE_REPO='offline/test')
    def release(version, success=True):
        p = subprocess.run(['/bin/bash', str(repo / 'release.sh'), version, '離線續跑測試'],
                           env=release_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        check((p.returncode == 0) == success, p.stdout)
        return p.stdout
    def count(path, line):
        return path.read_text().splitlines().count(line)
    output = release('00.00.01') + release('00.00.01')
    check(count(pushlog, 'v00.00.01') == 1, 'tag 被推送兩次')
    check(count(ghlog, 'created v00.00.01') == 1, 'Release 被建立兩次')
    for text in ('建立 v00.00.01', '推送 v00.00.01', '建立 GitHub Release v00.00.01', '上傳 codenv-00.00.01.dmg'):
        check('已經做過：' + text + '，跳過' in output, '缺少跳過訊息：' + text + '\n' + repr(output))
    print('通過：同版本跑兩次，Release 建立 1 次、tag 推送 1 次；四種跳過訊息齊全')

    (state / 'fail-before').touch()
    release('00.00.02', success=False)
    release('00.00.02')
    check(count(pushlog, 'v00.00.02') == count(ghlog, 'created v00.00.02') == 1, 'push 後中斷復原失敗')
    (state / 'fail-after').touch()
    release('00.00.03', success=False)
    release('00.00.03')
    check(count(pushlog, 'v00.00.03') == count(ghlog, 'created v00.00.03') == 1, 'Release 後中斷復原失敗')
    (state / 'v00.00.03.assets').write_text('other.zip\n')
    release('00.00.03')
    release('00.00.03')
    check(count(ghlog, 'upload v00.00.03') == 1, '缺少資產未恰好補傳一次')
    print('通過：push 後中斷、Release 建立後中斷均可接續；缺少 DMG 只補傳 1 次（--clobber）')
    # 中斷點：只有本機 tag，還沒推送，也還沒有 Release。
    git('tag', '-a', 'v00.00.04', '-m', '模擬打 tag 後中斷')
    release('00.00.04')
    release('00.00.04')
    check(count(pushlog, 'v00.00.04') == count(ghlog, 'created v00.00.04') == 1, '本機 tag 中斷復原失敗')
    print('通過：只有本機 tag 時可接續，重跑仍只推送與建立 Release 各 1 次')
    git('commit', '--allow-empty', '-qm', '不同的 HEAD')
    before = (pushlog.read_text(), ghlog.read_text(), (repo / 'Info.plist').read_bytes())
    output = release('00.00.03', success=False)
    check('指向別的 commit' in output, '未阻擋 tag 衝突')
    check(before == (pushlog.read_text(), ghlog.read_text(), (repo / 'Info.plist').read_bytes()), 'tag 衝突仍產生副作用')
    print('通過：tag 指向不同 commit 時立即停止，未推送、未呼叫 gh、未改版本')

    board_dir = base / 'board'
    board_dir.mkdir()
    board = board_dir / 'collab.json'
    agy_calls = board_dir / 'calls'
    agy_calls.touch()
    gate = board_dir / 'finish-second'
    fake_agy = board_dir / 'agy'
    executable(fake_agy, f'''#!/bin/bash
set -eu
case "$*" in
    *step-one*) step=one ;;
    *step-two*) step=two ;;
    *) exit 95 ;;
esac
echo "$step" >> {shlex.quote(str(agy_calls))}
if [ "$step" = two ]; then
    while [ ! -f {shlex.quote(str(gate))} ]; do sleep 0.05; done
fi
printf '測試完成\\nHANDOFF: done\\n'
''')
    data = {'items': [], 'goals': [{'id': 'aaaaaa', 'status': 'active', 'title': '續跑測試', 'steps': [
        {'id': sid, 'text': text, 'state': 'todo', 'owner': 'gemini3.8flash', 'mode': 'read', 'cwd': str(board_dir)}
        for sid, text in [('111111', 'step-one'), ('222222', 'step-two')]]}]}
    board.write_text(json.dumps(data))
    runner_env = dict(env, CODENV_COLLAB_FILE=str(board), CODENV_AGY=str(fake_agy),
                      CODENV_AGY_PET_SAY='/usr/bin/true', CODENV_AGY_IDLE='0.5')
    # 匯入原始執行器，不改檔：只在測試程序替換連網檢查並縮短輪詢。
    # 額外將 urlopen 設為必定拋錯，防止測試意外連網。
    runner_code = '''import importlib.machinery, importlib.util, os, pathlib, sys, time
loader = importlib.machinery.SourceFileLoader('resume_runner', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
def no_network(*a, **k):
    raise AssertionError('測試禁止網路')
m.urllib.request.urlopen = no_network
m.online = lambda: True
sleep = m.time.sleep
m.time.sleep = lambda seconds: sleep(min(seconds, .05))
mode = sys.argv[2]
runner = m.AgyRunner()
if mode == 'run':
    barrier = sys.argv[3]
    if barrier:
        pathlib.Path(barrier + '.' + str(os.getpid())).touch()
        while not pathlib.Path(barrier).exists():
            sleep(.01)
    acquire = runner.acquire
    def recorded_acquire():
        acquired = acquire()
        pathlib.Path(m.RUNS, 'lock-' + str(os.getpid())).write_text(str(acquired))
        return acquired
    runner.acquire = recorded_acquire
    runner.main()
elif mode == 'claim-check':
    assert runner.acquire()
    pick = runner.next_step()
    assert pick is not None
    runner.update_step(pick[1]['id'], lambda g, st: st.update(state='done'))
    before = m.load()
    runner.launch(*pick)
    assert runner.proc is None and m.load() == before, '領取複查未擋住已完成步驟'
elif mode == 'wait':
    def no_start(*a, **k):
        raise AssertionError('wait 不應啟動執行器')
    m.agy_start = no_start
    m.wait_cmd(['222222', '--timeout', '2s'])
'''
    log_path = board_dir / 'runner.log'
    def start(mode='run', barrier=''):
        with log_path.open('a') as log:
            p = subprocess.Popen([sys.executable, '-c', runner_code, str(root / 'scripts/codenv-todo'), mode, str(barrier)],
                                 env=runner_env, stdout=log, stderr=log)
        processes.append(p)
        return p
    def steps():
        return json.loads(board.read_text())['goals'][0]['steps']
    def calls():
        return collections.Counter(agy_calls.read_text().splitlines())
    try:
        # 同一個閘門同時放行兩個程序，記錄真正 acquire 的回傳值。
        barrier = board_dir / 'start-race'
        contenders = [start(barrier=barrier), start(barrier=barrier)]
        until(lambda: len(list(board_dir.glob('start-race.*'))) == 2, '兩個執行器就緒')
        barrier.touch()
        runs = board_dir / 'agy-runs'
        until(lambda: len(list(runs.glob('lock-*'))) == 2, '兩個執行器競爭鎖')
        results = [(p, (runs / f'lock-{p.pid}').read_text()) for p in contenders]
        check(sorted(result for _, result in results) == ['False', 'True'], '兩個執行器未恰好一個拿到鎖')
        first = next(p for p, result in results if result == 'True')
        loser = next(p for p, result in results if result == 'False')
        loser.wait(timeout=5)
        check(loser.returncode == 0, log_path.read_text())
        print('通過：兩個執行器同時競爭，只有 1 個拿到 runner.lock')
        until(lambda: steps()[0]['state'] == 'done' and steps()[1].get('agyPid') and calls()['two'] == 1,
              '第一步完成、第二步正在執行')
        snapshot = dict(steps()[0])
        orphan = steps()[1]['agyPid']
        first.kill()  # SIGKILL，不給 shutdown 清理機會
        first.wait(timeout=5)
        # 模擬心跳過期；執行器已死，這時只有測試在寫看板。
        data = json.loads(board.read_text())
        data['goals'][0]['steps'][1]['heartbeat'] = '2000-01-01T00:00:00+00:00'
        board.write_text(json.dumps(data))
        # pause.json 期間也要完成復原，但不能領走工作。
        runs = board_dir / 'agy-runs'
        (runs / 'pause.json').write_text(json.dumps({'until': '2099-01-01T00:00:00+00:00', 'reason': '測試暫停'}))
        second = start()
        until(lambda: steps()[1]['state'] == 'blocked', '中斷的 doing 改成 blocked')
        recovered = dict(steps()[1])
        check('執行器中斷' in recovered.get('note', ''), '缺少執行器中斷說明')
        check(recovered.get('agyPid') is None and recovered.get('heartbeat') is None, '復原未清掉 pid 或心跳')
        competitor = start()
        competitor.wait(timeout=5)
        check(competitor.returncode == 0 and second.poll() is None, '單例鎖未擋住第二個執行器')
        check((runs / f'lock-{competitor.pid}').read_text() == 'False', '競爭者拿到鎖')
        check(steps()[1] == recovered and calls() == {'one': 1, 'two': 1}, '暫停期間重複復原或重領')
        check(steps()[0] == snapshot, 'done 在復原時被修改')
        (runs / 'pause.json').unlink()
        second.wait(timeout=5)
        check(second.returncode == 0, log_path.read_text())
        third = start()
        third.wait(timeout=5)
        check(third.returncode == 0 and steps()[1] == recovered, 'blocked 重啟後被改動')
        check(calls() == {'one': 1, 'two': 1}, '已完成或中斷步驟被重做')
        check(steps()[0] == snapshot, '第一步 done 的結果被覆蓋')
        print('通過：SIGKILL 後重啟，已完成步驟不重跑；中斷步驟變 blocked、note 記錄執行器中斷，agy 不再被呼叫')
        print('通過：pause.json 期間完成復原；解除暫停及再次重啟仍不重領 blocked')

        # 獨立驗證全 done：模擬人工完成第二步，不經過 agy。
        data = json.loads(board.read_text())
        data['goals'][0]['steps'][1]['state'] = 'done'
        board.write_text(json.dumps(data))
        completed = steps()
        fourth = start()
        fourth.wait(timeout=5)
        check(fourth.returncode == 0 and steps() == completed, '全 done 重啟後步驟被修改')
        check(calls() == {'one': 1, 'two': 1}, '全 done 重啟仍呼叫 agy')
        print('通過：全 done 重啟，沒有新增 agy 呼叫')

        # 模擬 next_step 選出候選後、launch 領取前，步驟已由別處完成。
        data['goals'][0]['steps'][1]['state'] = 'todo'
        board.write_text(json.dumps(data))
        recheck = start(mode='claim-check')
        recheck.wait(timeout=5)
        check(recheck.returncode == 0 and calls() == {'one': 1, 'two': 1}, log_path.read_text())
        check(steps()[1]['state'] == 'done', '領取複查覆蓋了 done')
        print('通過：候選選出後改成 done，領取時複查擋住重做')

        # 獨立驗證 wait：執行器與 agy 都已死、心跳過期，直接標卡住。
        data = json.loads(board.read_text())
        data['goals'][0]['steps'][1].update(state='doing', agyPid=None,
            heartbeat='2000-01-01T00:00:00+00:00', note='')
        board.write_text(json.dumps(data))
        (runs / 'runner.json').unlink(missing_ok=True)
        waiter = start(mode='wait')
        waiter.wait(timeout=5)
        check(waiter.returncode == 0, log_path.read_text())
        check(steps()[1]['state'] == 'blocked' and '執行器中斷' in steps()[1]['note'], 'wait 未將過期步驟標卡住')
        check(calls() == {'one': 1, 'two': 1}, 'wait 又呼叫 agy')
        print('通過：wait 偵測雙方已死且心跳過期，直接標 blocked，未啟動執行器或呼叫 agy')
    finally:
        for p in processes:
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait()
        # 測試失敗時，也清掉只屬於這次暫存看板的假 agy 群組。
        pids = {st.get('agyPid') for st in steps()}
        if 'orphan' in locals():
            pids.add(orphan)
        for pid in pids:
            if pid:
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
    print('全部通過（離線；暫存資料已隔離，結束自動清理）')
PY
