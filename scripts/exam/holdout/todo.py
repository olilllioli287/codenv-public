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
    elif case == 'C50':
        # 11/8 起沒有每日件數上限：今天 Flash 已做 30 件，第 31 件照派；CODENV_AGY_LIMITS 設了上限才擋；agy 自己的額度剩不到 5% 才暫停那個名字
        import json
        from datetime import datetime
        assert m.LIMITS == {}, ('預設不該有上限', m.LIMITS)
        goals = [{'id': 'g1', 'title': 't', 'status': 'active', 'steps': [
            {'id': 'sa', 'text': '阿公的步驟', 'state': 'todo', 'owner': 'gemini4.0argon'},
            {'id': 'sf', 'text': 'Flash 的第 31 件', 'state': 'todo', 'owner': 'gemini3.8flash'}]}]
        Path(temp / 'collab.json').write_text(json.dumps({'goals': goals, 'items': []}, ensure_ascii=False))
        Path(m.RUNS, 'count.json').write_text(json.dumps({'date': datetime.now().strftime('%Y-%m-%d'), 'counts': {'gemini3.8flash': 30, 'gemini4.0argon': 5}, 'noticed': []}))
        def pick():
            m._usage_cache.update(at=0.0, rows=None)
            r = m.AgyRunner().next_step()
            return r[1]['id'] if r else None
        ok = 'Gemini Models\tFive Hour Limit Remaining\t90%\t2026-11-08T08:00:00Z\nGemini Models\tWeekly Limit Remaining\t80%\t2026-11-12T08:00:00Z\nGemini 4 Argon\tWeekly Limit Remaining\t88%\t2026-11-12T08:00:00Z\n'
        with patch.dict(m.ENV, CODENV_AGY_USAGE_FAKE=ok):
            assert pick() == 'sa', ('沒設上限時阿公第 6 件被擋', pick())     # 照看板順序：阿公的步驟在前，今天已 5 件也照派
            with patch.dict(m.LIMITS, {'gemini4.0argon': 5, 'gemini3.8flash': 30}):
                assert pick() is None, ('設了上限（CODENV_AGY_LIMITS）要擋', pick())
        # Flash 5 小時剩 3%：先不派 Flash，阿公照派；Flash 每週也一樣
        for row in ['Gemini Models\tFive Hour Limit Remaining\t3%\t2026-11-08T08:00:00Z', 'Gemini Models\tWeekly Limit Remaining\t4%\t2026-11-12T08:00:00Z']:
            with patch.dict(m.ENV, CODENV_AGY_USAGE_FAKE=row + '\nGemini 4 Argon\tWeekly Limit Remaining\t88%\t2026-11-12T08:00:00Z'):
                assert pick() == 'sa', '阿公沒被 Flash 的額度連累'
        Path(temp / 'collab.json').write_text(json.dumps({'goals': [dict(goals[0], steps=goals[0]['steps'][1:])], 'items': []}, ensure_ascii=False))
        for row in ['Gemini Models\tFive Hour Limit Remaining\t3%\t2026-11-08T08:00:00Z']:
            with patch.dict(m.ENV, CODENV_AGY_USAGE_FAKE=row):
                assert pick() is None, 'Flash 5 小時額度剩 3% 仍派了'
        # 剩 5% 不算低於 5%；查不到（空輸出）不擋
        with patch.dict(m.ENV, CODENV_AGY_USAGE_FAKE='Gemini Models\tFive Hour Limit Remaining\t5%\t2026-11-08T08:00:00Z'):
            assert pick() == 'sf', '剛好 5% 不該擋'
        with patch.dict(m.ENV, CODENV_AGY_USAGE_FAKE=''):
            assert pick() == 'sf', '查不到額度時不該擋'
        # 阿公只看每週：每週剩 4% 擋阿公
        Path(temp / 'collab.json').write_text(json.dumps({'goals': [dict(goals[0], steps=goals[0]['steps'][:1])], 'items': []}, ensure_ascii=False))
        with patch.dict(m.ENV, CODENV_AGY_USAGE_FAKE='Gemini 4 Argon\tWeekly Limit Remaining\t4%\t2026-11-12T08:00:00Z'):
            assert pick() is None, '阿公每週剩 4% 仍派了'
    elif case == 'C51':
        import json
        from contextlib import redirect_stdout, redirect_stderr
        from io import StringIO
        m.FILE = str(temp / 'collab.json')
        original = {'goals': [
            {'id': 'done01', 'title': '完成項', 'status': 'done', 'steps': []},
            {'id': 'prop01', 'title': '提議項', 'status': 'proposed', 'steps': []},
            {'id': 'active1', 'title': '進行中', 'status': 'active', 'steps': []}], 'items': []}
        Path(m.FILE).write_text(json.dumps(original), encoding='utf-8')
        with redirect_stdout(StringIO()):
            m.goal_cmd(['rm', 'done01'], None)
        backup = json.loads(Path(m.FILE + '.bak').read_text(encoding='utf-8'))
        assert backup == original, '刪除前 .bak 不是原始看板'
        assert [g['id'] for g in json.loads(Path(m.FILE).read_text(encoding='utf-8'))['goals']] == ['prop01', 'active1']
        before = Path(m.FILE).read_bytes()
        try:
            with redirect_stdout(StringIO()), redirect_stderr(StringIO()):
                m.goal_cmd(['rm', 'active1'], None)
        except SystemExit:
            pass
        else:
            raise AssertionError('允許刪除進行中的目標')
        assert Path(m.FILE).read_bytes() == before, '拒絕刪除後看板仍被修改'
    elif case == 'C60':
        import contextlib, io
        assert 'codenv-todo archive' in m.__doc__, 'help 缺少 archive 說明'
        calls = []
        def fake_app_call(req, feature, timeout=35):
            calls.append((req, feature))
            if req.get('target') == '工作分支':
                return {'ok': False, 'error': '「工作分支」正在工作中，請等它閒下來再封存（codenv-todo team 看狀態）'}
            return {'ok': True, 'name': req.get('target'), 'id': '12345678'}
        with patch.object(m, 'app_call', fake_app_call), patch.dict(os.environ, {'CODENV_CONVERSATION': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'}):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                m.main(['archive', '閒置分支'])
            assert '已封存：「閒置分支」（id 12345678）' in out.getvalue(), out.getvalue()
            assert calls[-1] == ({'cmd': 'archive', 'conv': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'target': '閒置分支'}, 'archive'), calls[-1]
            err = io.StringIO()
            try:
                with contextlib.redirect_stderr(err):
                    m.main(['archive', '工作分支'])
            except SystemExit as e:
                assert e.code == 1
            else:
                raise AssertionError('工作中的聊天室應拒絕封存')
            assert '正在工作中' in err.getvalue(), err.getvalue()
    else:
        raise AssertionError('未知案例：' + case)
print('斷言通過 ' + case)
