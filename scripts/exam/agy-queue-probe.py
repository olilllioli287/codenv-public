#!/usr/bin/env python3
"""Black-box queue ordering probe for C150-C152."""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

state_dir, mode, case = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
probe = state_dir / 'agy-test.jsonl'
release = state_dir / 'agy-test-release'
chief_name = case + 'Chief'

def wait_for(predicate, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(0.1)
    return False

def events():
    try:
        return [json.loads(line) for line in probe.read_text(encoding='utf-8').splitlines() if line.strip()]
    except FileNotFoundError:
        return []

def event_name(e):
    return e.get('event', e.get('type', ''))

def event_text(e):
    for key in ('text', 'message', 'input', 'prompt'):
        value = e.get(key)
        if isinstance(value, str):
            return value
    return ''

def wait_event(name, token=None, seconds=20):
    return wait_for(lambda: any(event_name(e) == name and (token is None or token in json.dumps(e, ensure_ascii=False)) for e in events()), seconds)

state = json.loads((state_dir / 'state.json').read_text(encoding='utf-8'))
sessions = state.get('sessions', [])
chief = next((s for s in sessions if s.get('name') == chief_name and s.get('groups') is not None), None)
assert chief, f'找不到測試總指揮 {chief_name!r}；sessions={sessions!r}'
chief_id = chief.get('chief')
assert chief_id, f'總指揮資料沒有總指揮聊天室 id：{chief!r}'

env = os.environ.copy()
env.update(CODENV_STATE_DIR=str(state_dir), CODENV_BROWSER_DIR=str(state_dir / 'browser'), CODENV_CONVERSATION=str(chief_id))
create = subprocess.run(['codenv-todo', 'new', case + 'Agy', '--engine', 'agy', '--dir', str(state_dir.parent / 'project'), '--model', 'gemini-4-hydrogen-high'], text=True, capture_output=True, env=env, timeout=25)
assert create.returncode == 0, f'無法建立隔離測試 agy 聊天室：{create.stdout}\n{create.stderr}'
team = subprocess.run(['codenv-todo', 'team', '--by', chief_name], text=True, capture_output=True, env=env, timeout=15)
assert team.returncode == 0, f'無法列出測試聊天室：{team.stdout}\n{team.stderr}'
target_match = re.search(r'^\s*(?:[-*]\s*)?【agy】(.+?)(?:\s|$)', team.stdout, re.M)
assert target_match, f'team 輸出沒有 agy 聊天室：{team.stdout}'
target = target_match.group(1).strip()

def send(text, wait=False, timeout=12):
    args = ['codenv-todo', 'send', target, text]
    if wait:
        args += ['--wait', '--timeout', str(timeout)]
    return subprocess.run(args, text=True, capture_output=True, env=env, timeout=timeout + 5)

if case == 'C150':
    first, second = 'C150_FIRST', 'C150_QUEUED'
    initial = send(first)
    assert initial.returncode == 0, f'第一則送出失敗：{initial.stdout} {initial.stderr}'
    assert wait_for(lambda: Path(str(probe) + '.busy').exists()), '假 agy 未進入 busy 狀態'
    queued = subprocess.Popen(['codenv-todo', 'send', target, second, '--wait', '--timeout', '2'], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    assert wait_event('queued', second), f'探針沒有記錄第二則已排隊：{events()!r}'
    time.sleep(2.5)
    returned_while_queued = queued.poll() is not None
    if returned_while_queued:
        out, err = queued.communicate(timeout=5)
    release.touch()
    if not returned_while_queued:
        out, err = queued.communicate(timeout=20)
    issues = []
    if queued.returncode != 0 or any(word in out + err for word in ('失敗', '逾時', '未讀入')):
        issues.append(f'訊息已排隊時應回報已排隊或成功，實際 returncode={queued.returncode}, stdout={out!r}, stderr={err!r}')
    elif not any(word in out + err for word in ('已排隊', '排入聊天室佇列', '已送達', '已讀入', '已送出', '成功')):
        issues.append(f'沒有回報已排隊或成功：stdout={out!r}, stderr={err!r}')
    if not wait_event('processed', second):
        issues.append(f'放行後排隊訊息未被處理：{events()!r}')
    processed = [e for e in events() if event_name(e) == 'processed']
    texts = [event_text(e) for e in processed]
    first_indexes = [i for i, text in enumerate(texts) if first in text]
    second_indexes = [i for i, text in enumerate(texts) if second in text]
    if not (len(first_indexes) == 1 and len(second_indexes) == 1 and first_indexes[0] < second_indexes[0]):
        issues.append(f'處理次數／順序錯誤：{processed!r}')
    assert not issues, '\n'.join(issues)
    print('  通過：忙碌時回報已排隊；wait 未在排隊期間逾時；放行後依序且各處理一次')
elif case == 'C151':
    first, second = 'C151_ORDINARY_ERROR', 'C151_QUEUED'
    assert send(first).returncode == 0
    assert wait_for(lambda: Path(str(probe) + '.ordinary-error-window').exists()), '一般錯誤窗口沒有出現'
    queued = send(second)
    assert queued.returncode == 0, f'第二則排隊送達失敗：{queued.stdout} {queued.stderr}'
    assert wait_event('queued', second), f'探針沒有記錄第二則排隊：{events()!r}'
    assert wait_event('processed', second), f'一般錯誤後第二則沒有被處理：{events()!r}'
    ev = events()
    starts = [e for e in ev if event_name(e) == 'process_started']
    exits = [e for e in ev if event_name(e) == 'process_exit']
    processed = [e for e in ev if event_name(e) == 'processed']
    texts = [event_text(e) for e in processed]
    assert len(starts) == 1 and not exits, f'一般錯誤不應重啟 agy：starts={starts!r} exits={exits!r}'
    first_indexes = [i for i, text in enumerate(texts) if first in text]
    second_indexes = [i for i, text in enumerate(texts) if second in text]
    assert len(first_indexes) == 1 and len(second_indexes) == 1 and first_indexes[0] < second_indexes[0], f'訊息遺失／重複／亂序：{processed!r}'
    print('  通過：一般錯誤後 agy 程序未重啟，後續排隊訊息依序只處理一次')
elif case == 'C152':
    first, second = 'C152_RETRY_FIRST', 'C152_INTERRUPT_SECOND'
    first_cmd = subprocess.Popen(['codenv-todo', 'send', target, first], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    assert wait_for(lambda: Path(str(probe) + '.retry-window').exists(), 20), '重試等待窗口沒有出現'
    queued = send(second)
    print(f'  C152 插話送達回覆：returncode={queued.returncode}, stdout={queued.stdout!r}, stderr={queued.stderr!r}, first_request_still_waiting={first_cmd.poll() is None}')
    assert queued.returncode == 0, f'重試期間插話送出失敗：{queued.stdout} {queued.stderr}'
    first_out, first_err = first_cmd.communicate(timeout=20)
    assert first_cmd.returncode == 0, f'第一則重試訊息送出失敗：{first_out} {first_err}'
    accepted = next((e for e in events() if event_name(e) == 'send_accepted' and second in json.dumps(e, ensure_ascii=False)), None)
    retry_queue = next((e for e in events() if event_name(e) == 'queued_during_retry'), None)
    assert accepted and accepted.get('queuedAtSend') is True, f'插話沒有在重試期間被接受／排隊：{events()!r}'
    assert retry_queue and retry_queue.get('uuid') == accepted.get('uuid'), f'重試佇列事件沒有對應插話訊息：accepted={accepted!r}, retry_queue={retry_queue!r}'
    assert wait_for(lambda: any(event_name(e) == 'processed' and second in event_text(e) for e in events()), 20), f'插話訊息沒有被處理：{events()!r}'
    ev = events()
    processed = [e for e in ev if event_name(e) == 'processed']
    texts = [event_text(e) for e in processed]
    first_indexes = [i for i, text in enumerate(texts) if first in text]
    second_indexes = [i for i, text in enumerate(texts) if second in text]
    assert first_indexes and second_indexes and first_indexes[0] < second_indexes[0], f'插話覆蓋重試訊息或順序倒置：{processed!r}'
    assert len(second_indexes) == 1, f'插話訊息應只處理一次：{processed!r}'
    retried = [e for e in processed if first in event_text(e) and e.get('retry')]
    assert retried, f'重試中的第一則沒有優先完成：{processed!r}'
    print('  通過：重試中的訊息先完成，插話在後且只處理一次')
else:
    raise SystemExit('未知案例 ' + case)
