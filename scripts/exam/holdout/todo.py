import os
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from todo_support import load, finish

case, root = sys.argv[1], Path(sys.argv[2])
with tempfile.TemporaryDirectory(prefix='exam-holdout-') as directory:
    temp = Path(directory)
    m = load(root, temp)
    if case == 'A11':
        for text in ['審查：429 rate limit quota 是錯誤訊息', '審查：429 rate limit\nHANDOFF: done']:
            result, step, refunds = finish(m, temp, text)
            assert result[1] == 'done', ('回答文字誤判額度', result[1:4])
            assert 'quotaBack' not in step and not refunds
            assert not (Path(m.RUNS) / 'pause.json').exists()
        for err, log in [('RESOURCE_EXHAUSTED 429', ''), ('', 'rate limit exceeded')]:
            result, step, refunds = finish(m, temp, '執行失敗', err, log, code=1)
            assert result[1] == 'todo' and step['quotaBack'] == 1
            assert refunds == [('gemini3.8flash', '2026-11-04')], refunds
            assert (Path(m.RUNS) / 'pause.json').exists()
    elif case == 'A12':
        # 假 TMPDIR 指向非暫存路徑，也不能擴大允許範圍（不讀寫該路徑）。
        with patch.dict(m.ENV, TMPDIR='/Volumes/exam-untrusted'):
            fake_root = m.ENV['TMPDIR']
            assert not m.is_temp(fake_root + '/child'), '呼叫者 TMPDIR 繞過限制'
        assert m.is_temp('/private/tmp/exam-child')
        assert not m.is_temp('/private/tmp/')
        captured = []
        def popen(*args, **kw):
            captured.append(kw['env'])
            return SimpleNamespace(pid=12345)
        step = {'id': 'abcdef', 'owner': 'gemini3.8flash', 'state': 'todo', 'text': '環境測試', 'cwd': str(temp), 'mode': 'read'}
        runner = m.AgyRunner()
        runner.log = lambda *a: None
        runner.update_step = lambda sid, fn: fn({'status': 'active'}, step)
        m.today_counts = lambda: {'date': '2026-11-05', 'counts': {}}
        m.write_counts = lambda c: None
        m.agy_prompt = lambda *a: '測試'
        values = {'PATH': '/usr/bin:/bin', 'HOME': str(temp), 'LANG': 'zh_TW.UTF-8', 'LC_ALL': 'C', 'SECRET_TOKEN': '不可傳遞', 'TMPDIR': '/untrusted'}
        with patch.dict(m.ENV, values, clear=True), patch.object(m.os, 'confstr', return_value=str(temp / 'system-tmp')), patch.object(m.subprocess, 'Popen', popen):
            runner.launch({'id': 'bbbbbb'}, step)
        assert len(captured) == 1
        env = captured[0]
        assert 'SECRET_TOKEN' not in env, '機密環境被傳入'
        for key in ['HOME', 'LANG', 'LC_ALL']:
            assert env[key] == values[key]
        assert env['PATH'].endswith(values['PATH'])
        assert env['TMPDIR'] == str(temp / 'system-tmp')
    else:
        raise AssertionError('未知案例：' + case)
print('斷言通過 ' + case)
