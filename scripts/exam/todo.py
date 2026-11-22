import sys
import tempfile
from pathlib import Path
from todo_support import load, finish

case, root = sys.argv[1], Path(sys.argv[2])
with tempfile.TemporaryDirectory(prefix='exam-todo-') as directory:
    temp = Path(directory)
    m = load(root, temp)
    if case == 'A07':
        m.new_id, m.now = lambda: 'abcdef', lambda: '固定時間'
        for text, expected, owner in [
            ('聯絡 a@b.com', '聯絡 a@b.com', None),
            ('檢查 @State 宣告', '檢查 @State 宣告', None),
            ('修正 @gemini3.8flash', '修正', 'gemini3.8flash'),
            ('修正@gemini3.8flash', '修正', 'gemini3.8flash'),
        ]:
            step = m.parse_step(text)
            assert (step['text'], step.get('owner')) == (expected, owner), ('負責人誤拆', step)
        assert m.parse_step('聯絡 a@b.com', split_owner=False)['text'] == '聯絡 a@b.com'
    elif case == 'A08':
        for text, state, note, tail in [
            ('內容\nHANDOFF: need-user 等確認\n補充說明', 'blocked', '等確認', '補充說明'),
            ('HANDOFF: done\n補充\nHANDOFF: stuck 缺檔\n尾註', 'blocked', '缺檔', '尾註'),
            ('普通回答', 'done', '', '普通回答'),
            ('提到 HANDOFF: stuck', 'done', '', '提到 HANDOFF: stuck'),
        ]:
            result, _, _ = finish(m, temp, text)
            assert result[1] == state, ('HANDOFF 狀態錯誤', result[1:4])
            assert note in result[2] and tail in result[3], result
    elif case == 'A13':
        # 把步驟加到已完成的目標：目標要回到進行中（不然新步驟永遠不被做）
        import json
        Path(temp / 'collab.json').write_text(json.dumps({'goals': [{'id': 'g00001', 'title': 't', 'status': 'done', 'doneAt': 'x', 'steps': [
            {'id': 's00001', 'text': '舊步驟', 'state': 'done', 'owner': 'codenv_x'}, {'id': 's00002', 'text': '使用者驗收', 'state': 'done', 'owner': '你'}]}], 'items': []}))
        m.agy_start = lambda *a, **k: None
        m.step_cmd(['add', 'g00001', '新步驟'], by='codenv_x')
        g = json.loads(Path(temp / 'collab.json').read_text())['goals'][0]
        assert g['status'] == 'active' and 'doneAt' not in g, ('已完成目標加步驟後沒回到進行中', g)
        assert [x['text'] for x in g['steps']][-2:] == ['新步驟', '使用者驗收'], g['steps']
        assert g['steps'][-1]['state'] == 'todo', ('使用者驗收沒有重設', g['steps'])
    elif case == 'A14':
        # 搜尋詞：撇號、反斜線照原樣留著；成對引號才是片語
        for q, want in [("it's the user's", ["it's", 'the', "user's"]), ('C:\\Users\\foo', ['C:\\Users\\foo']),
                        ('"foo bar" baz', ['foo bar', 'baz']), ("'foo bar' baz", ['foo bar', 'baz'])]:
            assert m.split_terms(q) == want, (q, m.split_terms(q), want)
    elif case == 'A15':
        # agy 執行時間用單調時鐘：牆鐘被往前撥 40 分鐘（等於睡了一覺）不能讓做完的步驟被標「被切斷」
        result, _, _ = finish(m, temp, '正常的回答', jump=40 * 60)
        assert result[1] == 'done', ('牆鐘跳 40 分鐘後被誤判', result[1:4])
    elif case == 'A16':
        # 只有空白的搜尋詞（'" "'）不能組出壞 SQL
        import sqlite3
        con = sqlite3.connect(':memory:')
        assert m.run_search(con, '" "') == [], '空搜尋詞要回空'
        assert m.run_search(con, "   ") == []
    elif case == 'A17':
        # 看板單筆目標／步驟壞掉：goal ls、next 只跳過那筆並警告，好的目標照常列出，原檔不動
        import contextlib, io, json
        good = lambda i, t: {'id': i, 'title': t, 'status': 'active', 'steps': [{'id': i + 's', 'text': '步驟' + t, 'state': 'todo', 'owner': 'tester'}]}
        bads = [{'id': 'b1', 'status': 'active', 'steps': []}, {'title': '沒編號', 'steps': []}, None, 'oops',
                {'id': 'b4', 'title': 'status是list', 'status': ['x'], 'steps': []}, {'id': 'b5', 'title': 'state是dict', 'status': 'active', 'steps': [{'id': 'z', 'text': 't', 'state': {'a': 1}}]},
                {'id': 'b2', 'title': 'steps壞', 'status': 'active', 'steps': 'nope'},
                {'id': 'b3', 'title': '壞步驟', 'status': 'active', 'steps': [{'id': 'x', 'state': 'todo'}, {'text': '沒編號'}]}]
        for bad in bads:
            text = json.dumps({'items': [], 'goals': [good('g1', '好一'), bad, good('g2', '好二')]}, ensure_ascii=False)
            Path(temp / 'collab.json').write_text(text, encoding='utf-8')
            for fn, argv in ((m.goal_cmd, (['ls'], None)), (m.next_cmd, ('tester',))):
                out, err = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                    fn(*argv)
                assert '好一' in out.getvalue() and '好二' in out.getvalue(), (bad, fn.__name__, out.getvalue())
            assert Path(temp / 'collab.json').read_text(encoding='utf-8') == text, '原檔被改了'
        assert '警告' in err.getvalue(), '有壞筆時要警告'
    elif case == 'C60':
        import contextlib, io, os
        from unittest.mock import patch
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
    elif case == 'C93':
        import contextlib, io, json, os
        from types import SimpleNamespace
        from unittest.mock import patch
        assert 'codenv-todo handoff ' in m.__doc__ and 'codenv-todo handoff-finish ' in m.__doc__, 'help 缺 handoff 說明'
        assert 'codenv-todo archive --orphan' in m.__doc__ and '<閒置天數>' in m.__doc__, 'help 缺 orphan / TSV 格式說明'
        api_calls = []
        old_id = 'aaaaaaaa-1111-4111-8111-111111111111'
        new_id = 'bbbbbbbb-2222-4222-8222-222222222222'
        prep_file = temp / 'handoff.md'
        prep_file.write_text('# 假交接檔', encoding='utf-8')
        def fake_app_call(req, feature, timeout=35):
            api_calls.append((dict(req), feature, timeout))
            if req['cmd'] == 'handoff_info':
                return {'ok': True, 'id': old_id, 'name': '舊分支', 'commander': 'codenv', 'projectID': 'project-1',
                        'project': 'repo', 'dir': '/tmp/repo', 'subProject': '工具', 'area': '工具 › 編輯器', 'mcp': 'lite', 'topic': '修編輯器'}
            if req['cmd'] == 'handoff_create':
                return {'ok': True, 'id': new_id, 'name': req['name']}
            if req['cmd'] == 'handoff_send':
                return {'ok': True, 'sent': True}
            if req['cmd'] == 'handoff_finish':
                return {'ok': True, 'new': '舊分支', 'newId': new_id}
            if req['cmd'] == 'archive':
                if req.get('target') == 'cccccccc-3333-4333-8333-333333333333':
                    return {'ok': True, 'id': req['target'], 'name': '孤兒'}
                return {'ok': False, 'error': '這個聊天室已在某個總指揮 team 裡'}
            raise AssertionError(req)
        def assert_prep(args, expected_id):
            assert args == ['/fake/handoff-prep', expected_id], args
        with patch.object(m, 'app_call', fake_app_call), \
             patch.object(m.subprocess, 'run', side_effect=lambda args, **kwargs: (assert_prep(args, old_id), SimpleNamespace(returncode=0, stdout=str(prep_file) + '\n', stderr=''))[1]), \
             patch.dict(os.environ, {'CODENV_CONVERSATION': old_id, 'CODENV_HANDOFF_PREP': '/fake/handoff-prep'}):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                m.main(['handoff', '舊分支', '--model', 'sonnet'])
            assert '新聊天室：舊分支（交接中-' in out.getvalue(), out.getvalue()
            assert '舊聊天室仍保持原狀且未喚醒' in out.getvalue(), out.getvalue()
            assert [call[0]['cmd'] for call in api_calls] == ['handoff_info', 'handoff_create', 'handoff_send'], api_calls
            assert api_calls[1][0]['target'] == old_id and api_calls[1][0]['model'] == 'sonnet'
            opening = api_calls[2][0]['text']
            assert 'git log' in opening and 'SendMessage' in opening and '等總指揮確認' in opening, opening
            appended = prep_file.read_text(encoding='utf-8')
            assert 'projectID：project-1' in appended and 'MCP：lite' in appended and '工具 › 編輯器' in appended and '修編輯器' in appended, appended
            saved = json.loads(Path(m.handoff_pending_path()).read_text(encoding='utf-8'))
            assert saved[new_id]['oldID'] == old_id and saved[new_id]['handoffFile'] == str(prep_file), saved
            with contextlib.redirect_stdout(io.StringIO()):
                m.main(['handoff-finish', saved[new_id]['newName']])
            assert api_calls[-1][0] == {'cmd': 'handoff_finish', 'conv': old_id, 'oldID': old_id, 'newID': new_id}, api_calls[-1]
            assert json.loads(Path(m.handoff_pending_path()).read_text(encoding='utf-8')) == {}, '完成後 pending 應清除'
            with contextlib.redirect_stdout(io.StringIO()):
                m.main(['archive', '--orphan', 'cccccccc-3333-4333-8333-333333333333'])
            assert api_calls[-1][0] == {'cmd': 'archive', 'orphan': True, 'conv': old_id, 'target': 'cccccccc-3333-4333-8333-333333333333'}
            assert api_calls[-1][1] == 'archive --orphan'
            err = io.StringIO()
            try:
                with contextlib.redirect_stderr(err):
                    m.main(['archive', '--orphan', 'dddddddd-4444-4444-8444-444444444444'])
            except SystemExit as e:
                assert e.code == 1
            else:
                raise AssertionError('team 內聊天室必須拒絕 orphan 封存')
            assert 'team 裡' in err.getvalue(), err.getvalue()
    elif case == 'A20':
        # 代勾必須有原話、--by 名字和 codenv 注入的來源聊天室 ID；全部做完目標就完成。
        # 沒原話、沒名字、agy／手動名字、非使用者步驟或沒有聊天室 ID 都不收。
        import contextlib, io, json, os
        def goals():
            return {'items': [], 'goals': [{'id': 'g1', 'title': 't', 'status': 'active', 'steps': [
                {'id': 's1', 'text': '實作', 'state': 'done', 'owner': 'codenv_2'},
                {'id': 's2', 'text': '使用者驗收', 'state': 'todo', 'owner': '你'}]}]}
        def put(d): Path(temp / 'collab.json').write_text(json.dumps(d, ensure_ascii=False), encoding='utf-8')
        def run(argv, by, caller='11111111-1111-1111-1111-111111111111'):
            err = io.StringIO()
            old_caller = os.environ.get('CODENV_CONVERSATION')
            if caller is None:
                os.environ.pop('CODENV_CONVERSATION', None)
            else:
                os.environ['CODENV_CONVERSATION'] = caller
            try:
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
                    m.step_cmd(argv, by=by)
                return True
            except SystemExit:
                return False
            finally:
                if old_caller is None:
                    os.environ.pop('CODENV_CONVERSATION', None)
                else:
                    os.environ['CODENV_CONVERSATION'] = old_caller
        for argv, by in ((['s2', '完成'], 'codenv_1'), (['s2', '完成', '--note', '可以了'], None), (['s2', '完成', '--note', '   '], 'codenv_1'),
                         (['s2', '完成', '--note', '可以了'], 'gemini3.8flash'), (['s2', '完成', '--note', '可以了'], '手動flash'), (['s2', '完成', '--note', '可以了'], '你'),
                         (['s1', '完成', '--note', '可以了'], 'codenv_1')):
            put(goals())
            assert not run(argv, by), ('不該收的代勾被收了', argv, by)
            g = json.loads(Path(temp / 'collab.json').read_text())['goals'][0]
            assert g['steps'][1]['state'] == 'todo' and 'proxyBy' not in g['steps'][1] and g['status'] == 'active', ('被擋時不能改任何東西', argv, by, g)
        put(goals())
        assert not run(['s2', '完成', '--note', '可以了'], 'codenv_1', caller=None), '沒有來源聊天室仍允許代勾'
        st = json.loads(Path(temp / 'collab.json').read_text())['goals'][0]['steps'][1]
        assert st['state'] == 'todo' and 'proxyConversation' not in st, ('沒有來源聊天室不可留下代勾紀錄', st)
        put(goals())
        assert run(['s2', '完成', '--note', '  \n這個可以了  '], 'codenv_1'), '正常代勾被拒'
        g = json.loads(Path(temp / 'collab.json').read_text())['goals'][0]
        st = g['steps'][1]
        assert (st['state'], st['proxyBy'], st['proxyNote'], st['proxyConversation']) == (
            'done', 'codenv_1', '這個可以了', '11111111-1111-1111-1111-111111111111'), st
        assert g['status'] == 'done' and g.get('doneAt'), ('最後一步代勾後目標沒完成', g)
    elif case == 'A18':
        # 沙盒聊天室（有 CODENV_SCOPED_TOKEN）：看板讀寫全走 socket、不開 collab.json；rev 對不上就重讀重做；用的是專屬 token 和 CODENV_SOCKET
        import contextlib, hashlib, io, json, os, socket, threading
        sock = str(temp / 's')
        state = {'data': {'items': [], 'goals': []}, 'writes': 0, 'tokens': set(), 'cmds': []}
        rev = lambda: hashlib.sha256(json.dumps(state['data'], sort_keys=True).encode()).hexdigest()
        srv = socket.socket(socket.AF_UNIX); srv.bind(sock); srv.listen(8)
        def serve():
            while True:
                try: c, _ = srv.accept()
                except OSError: return
                buf = b''
                while not buf.endswith(b'\n'): buf += c.recv(65536)
                req = json.loads(buf); state['tokens'].add(req.get('token')); state['cmds'].append(req['cmd'])
                if req['cmd'] == 'board_read': r = {'ok': True, 'data': state['data'], 'rev': rev()}
                elif req['cmd'] == 'board_write':
                    if state['writes'] == 0 and not state.get('raced'):
                        state['raced'] = True      # 第一次寫之前先讓「別人」改一下：rev 對不上，client 要重讀重做
                        state['data']['items'].append({'id': 'other', 'col': 'locked'})
                    if req['rev'] != rev(): r = {'ok': False, 'conflict': True, 'error': 'conflict'}
                    else: state['data'] = req['data']; state['writes'] += 1; r = {'ok': True, 'rev': rev()}
                else: r = {'ok': False, 'error': 'no'}
                c.sendall((json.dumps(r) + '\n').encode()); c.close()
        threading.Thread(target=serve, daemon=True).start()
        os.environ['CODENV_SOCKET'] = sock
        m.SCOPED_TOKEN = 'scoped-tok'
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            m.goal_cmd(['add', '沙盒提的', '--done', '測'], 'sbx')
            m.goal_cmd(['ls'], None)
        assert '沙盒提的' in out.getvalue() and '提議中' in out.getvalue(), out.getvalue()
        assert state['writes'] == 1 and [g['title'] for g in state['data']['goals']] == ['沙盒提的'], state['data']
        assert any(it['id'] == 'other' for it in state['data']['items']), '重讀後要保留別人剛加的'
        assert state['tokens'] == {'scoped-tok'}, ('只能帶專屬 token', state['tokens'])
        assert not (temp / 'collab.json').exists(), '沙盒模式不能直接建／寫 collab.json'
        assert state['cmds'].count('board_write') == 2, ('第一次衝突、第二次成功', state['cmds'])
        srv.close()
    elif case == 'A21':
        # scoped search 索引不能放在 AI 工作台（CODENV_STATE_DIR）；放入 Claude 可寫的 projects 子目錄。
        import os
        old = {k: os.environ.get(k) for k in ('CODENV_SCOPED_TOKEN', 'CODENV_CLAUDE_HOME', 'CODENV_STATE_DIR')}
        try:
            os.environ['CODENV_SCOPED_TOKEN'] = 'scoped-tok'
            os.environ['CODENV_CLAUDE_HOME'] = str(temp / 'claude')
            os.environ['CODENV_STATE_DIR'] = str(temp / 'blocked-ai-workbench')
            m.SCOPED_TOKEN = 'scoped-tok'
            m.ENV = dict(os.environ)
            state, home = m.search_dirs()
            assert state == str(temp / 'claude' / 'projects' / '.codenv-search'), (state, home)
            assert state != os.environ['CODENV_STATE_DIR']
            assert home == str(temp / 'claude')
            # 工作台中繼資料與 transcripts 不可讀時，仍能從 Claude projects 建立索引。
            import sqlite3, json
            blocked = Path(temp) / 'blocked-ai-workbench'
            (blocked / 'transcripts').mkdir(parents=True)
            (blocked / 'state.json').write_text('{bad state', encoding='utf-8')
            (blocked / 'transcripts' / 'blocked.md').write_text('不可索引', encoding='utf-8')
            claude = Path(home) / 'projects' / 'proj'
            claude.mkdir(parents=True)
            transcript = claude / 'session.jsonl'
            transcript.write_text(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'text', 'text': 'sandbox searchable phrase'}]}}) + '\n', encoding='utf-8')
            con = sqlite3.connect(':memory:')
            con.executescript(m.SEARCH_DDL)
            m.update_index(con, str(blocked), home)
            hits = m.run_search(con, 'sandbox searchable phrase')
            assert hits, '工作台 state/transcripts 不可讀時仍須索引 Claude 紀錄'
            con.close()
        finally:
            for k, v in old.items():
                if v is None: os.environ.pop(k, None)
                else: os.environ[k] = v
    elif case == 'A22':
        # usage-log 的 pool 差異需跨 cutoff 使用 baseline，並按 resetAt 分週期累計。
        import contextlib, datetime, io, json
        now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
        iso = lambda delta: (now + datetime.timedelta(seconds=delta)).isoformat()
        m.ENV['CODENV_STATE_DIR'] = str(temp)
        log = temp / 'usage-log.jsonl'
        rows = [
            {'timestamp': iso(-200), 'pool': '跨界', 'kind': 'count', 'remaining': 80, 'total': 100, 'resetAt': iso(500)},
            {'timestamp': iso(-50), 'pool': '跨界', 'kind': 'count', 'remaining': 70, 'total': 100, 'resetAt': iso(500)},
            {'timestamp': iso(-10), 'pool': '重置', 'kind': 'percent', 'remaining': 100, 'total': 100, 'resetAt': iso(0)},
            {'timestamp': iso(5), 'pool': '重置', 'kind': 'percent', 'remaining': 100, 'total': 100, 'resetAt': iso(1000)},
            {'timestamp': iso(20), 'pool': '重置', 'kind': 'percent', 'remaining': 80, 'total': 100, 'resetAt': iso(1000)},
        ]
        log.write_text(''.join(json.dumps(row) + '\n' for row in rows), encoding='utf-8')
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            m.cmd_usage_log(['--since', '100s'])
        result = out.getvalue()
        assert '跨界：可觀測消耗 10 次' in result, result
        assert '重置：可觀測消耗 20%' in result, result
        assert '跨界' in result and '重置' in result

        # iter_usage_log 依 archive → active 產生，並保留每一條原始週期事件。
        archive = temp / 'usage-log.1.jsonl'
        archive.write_text(json.dumps({'timestamp': iso(-30), 'pool': '同額', 'kind': 'percent', 'remaining': 100, 'total': 100, 'resetAt': iso(0)}) + '\n', encoding='utf-8')
        log.write_text(json.dumps({'timestamp': iso(1), 'pool': '同額', 'kind': 'percent', 'remaining': 100, 'total': 100, 'resetAt': iso(1000)}) + '\n', encoding='utf-8')
        parsed = list(m.iter_usage_log(str(log)))
        assert [r['resetAt'] for r in parsed] == [m.usage_log_datetime(iso(0)), m.usage_log_datetime(iso(1000))], parsed
    elif case == 'A23':
        # 壓縮快照隔離 session、遮蔽機密、優先保留背景／待辦，並限制單次尾端讀取與 hook 例外。
        import contextlib, importlib.util, io, json, os, time
        from types import SimpleNamespace
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('compact_guard', str(Path(root) / 'scripts' / 'compact-guard.py'))
        cg = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cg)
        assert 'PRIVATE_URL_QUERY' not in cg.safe_path('https://example.invalid/path?token=PRIVATE_URL_QUERY')
        cdir = temp / 'compact-state'
        def run_cg(sub, payload):
            out = io.StringIO()
            with patch.dict(os.environ, {'CODENV_COMPACT_DIR': str(cdir)}), \
                 patch.object(sys, 'stdin', io.StringIO(json.dumps(payload, ensure_ascii=False))), \
                 contextlib.redirect_stdout(out):
                rc = cg.main(['compact-guard.py', sub])
            return SimpleNamespace(returncode=rc, stdout=out.getvalue(), stderr='')
        tx = temp / 'transcript.jsonl'
        rows = [
            {'type': 'user', 'timestamp': '2026-11-10T01:00:00Z', 'message': {'role': 'user', 'content': 'U0 最早的一句（只留最近 5 則，這句不該出現）'}},
            {'type': 'user', 'timestamp': '2026-11-10T01:01:00Z', 'message': {'role': 'user', 'content': 'U1 第一則保留的原話前<system-reminder>SECRET_SYS_REMINDER</system-reminder>後 sk-or-v1-AbCdEfGhIjKlMnOpQrStUvWx sk-ABCDEFGHIJKLMNOPQRSTUVWX gsk_ABCDEFGHIJKLMNOPQRSTUVWX ghp_ABCDEFGHIJKLMNOPQRSTUVWX AIzaABCDEFGHIJKLMNOPQRSTUVWX xoxb-ABCDEFGHIJKLMNOPQRSTUVWX Bearer abcdefghijklmnopqrstuvwxyzABCDEFGH aQ7zP9xK2mV6bN4cR8tY1uW5eD3fG0hJ'}},
            {'type': 'user', 'timestamp': '2026-11-10T01:03:00Z', 'turnOrigin': 'peer', 'message': {'role': 'user', 'content': '<cross-session-message>PEER_NOISE</cross-session-message>'}},
            {'type': 'user', 'timestamp': '2026-11-10T01:04:00Z', 'isCompactSummary': True, 'message': {'role': 'user', 'content': 'COMPACT_NOISE'}},
            {'type': 'user', 'timestamp': '2026-11-10T01:05:00Z', 'message': {'role': 'user', 'content': [
                {'type': 'image', 'source': {'type': 'base64', 'data': 'AA=='}},
                {'type': 'text', 'text': 'U2 附圖的原話；前<task-notification><task-id>PRIVATE_TASK</task-id></task-notification>後'},
            ]}},
            {'type': 'assistant', 'message': {'id': 'm1', 'role': 'assistant', 'content': [
                {'type': 'tool_use', 'id': 'tu1', 'name': 'Bash', 'input': {'command': 'sleep 10', 'description': '已完成的背景任務'}},
                {'type': 'tool_use', 'id': 'tu2', 'name': 'Bash', 'input': {'command': 'curl https://example.invalid/?token=PRIVATE_QUERY', 'description': '還在跑的長任務'}},
                {'type': 'tool_use', 'id': 'tu3', 'name': 'TodoWrite', 'input': {'todos': [
                    {'content': '做完的事', 'status': 'completed'},
                    {'content': '待辦甲：檢查設定', 'status': 'in_progress'},
                    {'content': '待辦乙：跑考卷', 'status': 'pending'},
                ]}},
                {'type': 'tool_use', 'id': 'tu4', 'name': 'Edit', 'input': {'file_path': '/proj/Sources/ChatSession.swift'}},
                {'type': 'tool_use', 'id': 'tu5', 'name': 'WebFetch', 'input': {'url': 'https://example.invalid/path?key=PRIVATE_URL_QUERY', 'query': 'PRIVATE_QUERY', 'prompt': 'PRIVATE_PROMPT'}},
            ]}},
            {'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 'tu1', 'content': 'Command running in background with ID: bg_done_1\nTOOL_RESULT_NOISE'}]}},
            {'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 'tu2', 'content': 'Command running in background with ID: bg_alive_2'}]}},
            {'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'text', 'text': '<task-notification><task-id>bg_done_1</task-id><status>completed</status></task-notification>'}]}},
            {'type': 'user', 'timestamp': '2026-11-10T01:06:00Z', 'message': {'role': 'user', 'content': 'U3 第三則原話<cross-session-message>PEER_NOISE</cross-session-message>仍要的文字'}},
            {'type': 'user', 'timestamp': '2026-11-10T01:07:00Z', 'message': {'role': 'user', 'content': 'U4 第四則原話<command-name>PRIVATE_COMMAND_NAME</command-name>結尾'}},
            {'type': 'user', 'timestamp': '2026-11-10T01:08:00Z', 'message': {'role': 'user', 'content': 'U5 第五則最新原話'}},
            {'type': 'assistant', 'message': {'id': 'm2', 'role': 'assistant', 'content': [{'type': 'text', 'text': 'HEAD_DROP_' + ('甲' * 1600) + '_TAIL_KEEP'}]}},
        ]
        tx.write_text('\n'.join(json.dumps(r, ensure_ascii=False) for r in rows) + '\n', encoding='utf-8')
        import builtins
        real_open = builtins.open
        opened = []
        def count_open(*args, **kwargs):
            opened.append(args[0])
            return real_open(*args, **kwargs)
        with patch('builtins.open', count_open):
            tail_records = cg.read_tail_records(str(tx))
        assert len(opened) == 1, ('transcript 必須只開啟／掃描一次', opened)
        assert cg.MAX_TAIL_BYTES == 16 << 20 and cg.MAX_SCAN_SECONDS <= 1.5
        assert not any(cg.real_user_text(x) and 'U0 最早的一句' in cg.real_user_text(x) for x in tail_records), '尾端掃描應在最近五則原話停下'
        timeout_tx = temp / 'timeout.jsonl'
        timeout_tx.write_text('\n'.join(json.dumps(r) for r in [
            {'type': 'user', 'message': {'role': 'user', 'content': 'older'}},
            {'type': 'assistant', 'message': {'id': 'newest', 'role': 'assistant', 'content': [{'type': 'text', 'text': 'already read'}]}},
        ]) + '\n', encoding='utf-8')
        with patch.object(cg.time, 'monotonic', side_effect=[0.0, 0.0, 2.0, 2.0]):
            timed_records = cg.read_tail_records(str(timeout_tx))
        assert len(timed_records) == 1 and timed_records[0].get('message', {}).get('id') == 'newest', timed_records
        cdir.mkdir(parents=True, exist_ok=True)
        stale = cdir / 'codenv-compact-stale.json'
        stale.write_text(json.dumps({'managed_by': cg.SNAPSHOT_MARKER}), encoding='utf-8')
        unowned_stale = cdir / 'old_session.json'
        unowned_stale.write_text('{}', encoding='utf-8')
        old_t = time.time() - 9 * 86400
        os.utime(stale, (old_t, old_t))
        for _ in range(4):
            r = run_cg('pre-compact', {'session_id': 'sess-123', 'transcript_path': str(tx), 'trigger': 'auto', 'cwd': '/proj'})
            assert r.returncode == 0, r.stderr
        assert not stale.exists(), '超過 7 天且由本工具標記的快照應清掉'
        assert unowned_stale.exists(), '清檔不得刪除非本工具命名的檔案'
        assert (cdir / 'codenv-compact-sess-123.json').is_file() and (cdir / 'codenv-compact-sess-123.1.json').is_file() and (cdir / 'codenv-compact-sess-123.2.json').is_file()
        assert not (cdir / 'codenv-compact-sess-123.3.json').exists(), '每個 session 最多留 3 份快照'
        saved = json.loads((cdir / 'codenv-compact-sess-123.json').read_text(encoding='utf-8'))
        assert saved['managed_by'] == cg.SNAPSHOT_MARKER
        serialized = json.dumps(saved, ensure_ascii=False)
        for secret in ('sk-or-v1-AbCdEfGhIjKlMnOpQrStUvWx', 'sk-ABCDEFGHIJKLMNOPQRSTUVWX', 'gsk_ABCDEFGHIJKLMNOPQRSTUVWX',
                       'ghp_ABCDEFGHIJKLMNOPQRSTUVWX', 'AIzaABCDEFGHIJKLMNOPQRSTUVWX', 'xoxb-ABCDEFGHIJKLMNOPQRSTUVWX',
                       'abcdefghijklmnopqrstuvwxyzABCDEFGH', 'aQ7zP9xK2mV6bN4cR8tY1uW5eD3fG0hJ',
                       'PRIVATE_QUERY', 'PRIVATE_URL_QUERY', 'PRIVATE_PROMPT', 'curl https://example.invalid'):
            assert secret not in serialized, ('快照不應保存金鑰、命令或 URL query', secret)
        for src in ('startup', 'resume', 'clear', ''):
            r = run_cg('session-start', {'session_id': 'sess-123', 'source': src})
            assert r.returncode == 0 and r.stdout == '', (src, r.stdout)
        r = run_cg('session-start', {'session_id': 'sess-123', 'source': 'compact'})
        assert r.returncode == 0, r.stderr
        out = json.loads(r.stdout)['hookSpecificOutput']
        assert out['hookEventName'] == 'SessionStart'
        ctx = out['additionalContext']
        assert ctx.startswith('以下是壓縮前自動存下的上下文，以為準'), ctx[:80]
        for want in ('U1 第一則保留的原話', '[圖片]\nU2 附圖的原話', 'U3 第三則原話', 'U4 第四則原話 結尾', 'U5 第五則最新原話',
                     '_TAIL_KEEP', 'bg_alive_2（還在跑的長任務）', '待辦甲：檢查設定', '待辦乙：跑考卷', '/proj/Sources/ChatSession.swift',
                     'WebFetch', '[已遮蔽金鑰]', '[已遮蔽高熵字串]', 'U3 第三則原話 仍要的文字'):
            assert want in ctx, ('缺少應保留內容', want, ctx)
        for bad in ('U0 最早的一句', 'SECRET_SYS_REMINDER', 'PRIVATE_TASK', 'PRIVATE_COMMAND_NAME', 'PEER_NOISE', 'COMPACT_NOISE', 'TOOL_RESULT_NOISE',
                    'bg_done_1', '做完的事', 'HEAD_DROP_', 'PRIVATE_URL_QUERY', 'PRIVATE_PROMPT', 'PRIVATE_QUERY'):
            assert bad not in ctx, ('混入應排除內容', bad, ctx)
        # 缺少相同 session 時，即使 cwd 相同也不可撿其他聊天室快照。
        (cdir / 'codenv-compact-other-session.json').write_text(json.dumps({
            'managed_by': cg.SNAPSHOT_MARKER, 'session_id': 'other-session', 'cwd': '/proj', 'user_messages': [{'text': 'FOREIGN_CHAT_TEXT'}]
        }), encoding='utf-8')
        missing = run_cg('session-start', {'session_id': 'missing-session', 'source': 'compact', 'cwd': '/proj'})
        assert missing.returncode == 0 and missing.stdout == '', ('不得跨 session 或同 cwd 回退', missing.stdout)

        # 超過 item 數量時封頂；每個背景／待辦項目最多 200 字，且不保存 shell 命令。
        task_uses = [{'type': 'tool_use', 'id': f'task_{i:02d}', 'name': 'Bash',
                      'input': {'command': 'echo PRIVATE_COMMAND_' + str(i), 'description': f'背景項目{i:02d}' + ('D' * 240)}} for i in range(12)]
        todo_values = [{'content': f'待辦項目{i:02d}' + ('T' * 240), 'status': 'pending'} for i in range(25)]
        cap_rows = [
            {'type': 'assistant', 'message': {'id': 'cap', 'role': 'assistant', 'content': task_uses + [
                {'type': 'tool_use', 'id': 'todos', 'name': 'TodoWrite', 'input': {'todos': todo_values}},
                {'type': 'text', 'text': 'A' * 3000}]}},
            {'type': 'user', 'message': {'role': 'user', 'content': [
                {'type': 'tool_result', 'tool_use_id': f'task_{i:02d}', 'content': f'Command running in background with ID: task_{i:02d}'}
                for i in range(12)]}},
            {'type': 'user', 'message': {'role': 'user', 'content': 'CORE_USER original'}},
        ]
        cap_tx = temp / 'caps.jsonl'
        cap_tx.write_text('\n'.join(json.dumps(r, ensure_ascii=False) for r in cap_rows) + '\n', encoding='utf-8')
        snap_cap = cg.build_snapshot({'session_id': 'caps-session', 'transcript_path': str(cap_tx), 'cwd': '/proj'})
        assert len(snap_cap['background_tasks']) == 10, len(snap_cap['background_tasks'])
        assert len(snap_cap['todos']) == 20, len(snap_cap['todos'])
        assert all(len(x['desc']) <= 200 for x in snap_cap['background_tasks']), snap_cap['background_tasks']
        assert all(len(x['content']) <= 200 for x in snap_cap['todos']), snap_cap['todos']
        assert 'PRIVATE_COMMAND_' not in json.dumps(snap_cap, ensure_ascii=False)
        cap_ctx = cg.fit(snap_cap)
        assert len(cap_ctx) <= cg.LIMIT
        for want in ('CORE_USER original', 'task_11（背景項目11', '待辦項目19'):
            assert want in cap_ctx, ('優先區段遺失', want, cap_ctx[-1000:])
        assert cap_ctx.index('## 使用者最近原話') < cap_ctx.index('## 背景任務') < cap_ctx.index('## 未完成清單')
        assert all(len(line) <= 200 for line in cap_ctx.splitlines() if line.startswith('- ')), '背景／待辦顯示項目也須 <= 200 字'

        # 檢查最壞大小時依序縮減工具／檔案／助理內容，不能把待辦或背景任務整段截掉。
        stress = dict(snap_cap)
        stress['user_messages'] = [{'text': ('U' * 30000) + f'_ORIGINAL_END_{i}'} for i in range(5)]
        stress['background_tasks'] = [{'id': f'bg_{i:02d}', 'desc': 'B' * 200} for i in range(10)]
        stress['todos'] = [{'status': 'pending', 'content': f'TODO_{i:02d}_' + ('T' * 190)} for i in range(20)]
        stress['assistant_tail'] = 'A' * 1500
        stress['tool_calls'] = ['TOOL_' + ('X' * 200) for _ in range(20)]
        stress['files'] = ['FILE_' + ('F' * 200) for _ in range(15)]
        stress_ctx = cg.fit(stress)
        assert len(stress_ctx) <= cg.LIMIT
        for want in ('_ORIGINAL_END_4', 'bg_09', 'TODO_19_', '## 背景任務', '## 未完成清單'):
            assert want in stress_ctx, ('總長裁切不得丟背景任務／待辦', want)
        assert stress_ctx.index('## 使用者最近原話') < stress_ctx.index('## 背景任務') < stress_ctx.index('## 未完成清單')
        assert '## 最近工具動作' not in stress_ctx and '## 最近改的檔' not in stress_ctx

        # 長度上限 <= 12000：超長原話也保留結尾，並同時保住背景任務與待辦。
        big_rows = rows + [
            {'type': 'assistant', 'message': {'id': 'm3', 'role': 'assistant', 'content': [
                {'type': 'tool_use', 'id': f'b{i}', 'name': 'Bash', 'input': {'command': 'echo ' + ('X' * 200)}} for i in range(20)
            ] + [{'type': 'text', 'text': '乙' * 2000}]}},
            {'type': 'user', 'timestamp': '2026-11-10T01:09:00Z', 'message': {'role': 'user', 'content': 'U6_' + ('丙' * 9500) + '_U6_END'}},
        ]
        tx.write_text('\n'.join(json.dumps(r, ensure_ascii=False) for r in big_rows) + '\n', encoding='utf-8')
        run_cg('pre-compact', {'session_id': 'sess-big', 'transcript_path': str(tx), 'trigger': 'auto'})
        ctx_big = json.loads(run_cg('session-start', {'session_id': 'sess-big', 'source': 'compact'}).stdout)['hookSpecificOutput']['additionalContext']
        assert len(ctx_big) <= 12000, len(ctx_big)
        assert '_U6_END' in ctx_big and 'U5 第五則最新原話' in ctx_big, '超長時應保留最新原話結尾'
        assert 'bg_alive_2（還在跑的長任務）' in ctx_big and '待辦乙：跑考卷' in ctx_big, '超長時應保留背景任務與待辦'

        # stdin 讀取失敗或 JSON 解析遞迴過深都必須靜默 exit 0。
        class BrokenStdin:
            def read(self):
                raise OSError('simulated stdin failure')
        for bad_stdin in (BrokenStdin(), io.StringIO('[' * 2500 + '0' + ']' * 2500), io.StringIO('{broken')):
            out = io.StringIO()
            with patch.object(sys, 'stdin', bad_stdin), contextlib.redirect_stdout(out):
                rc = cg.main(['compact-guard.py', 'session-start'])
            assert rc == 0 and out.getvalue() == '', (rc, out.getvalue())
    elif case == 'A24':
        # 安全規格：機密遮蔽、系統標籤、路徑隔離、預設位置與注入上限。
        import contextlib, importlib.util, io, json, os, secrets
        from types import SimpleNamespace
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('compact_guard', str(Path(root) / 'scripts' / 'compact-guard.py'))
        cg = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cg)

        cdir = temp / 'compact-state'
        home = temp / 'isolated-home'
        tx = temp / 'security-transcript.jsonl'
        real_home = os.environ.get('HOME', str(Path.home()))
        formal = Path(real_home) / 'Library' / 'Application Support' / 'AI 工作台' / 'compact-state'
        outer_env_patch = patch.dict(os.environ, {'CODENV_COMPACT_DIR': str(cdir), 'HOME': str(home)}, clear=False)
        outer_env_patch.start()
        assert Path(os.environ['CODENV_COMPACT_DIR']).resolve() != formal.resolve(), 'A24 隔離後 CODENV_COMPACT_DIR 仍指向正式路徑'
        assert Path(os.environ['HOME']).resolve() != Path(real_home).resolve(), 'A24 隔離後 HOME 仍指向正式家目錄'
        secret_values = [
            'sk-' + 'A' * 30, 'nvapi-' + 'B' * 30, 'ghp_' + 'C' * 30,
            'Authorization: Bearer ' + 'D' * 32,
            'Authorization: bEaReR ' + 'E' * 32,
            'Q7mZ2vK9pL4xN8cR5tY1uW6eD3fG0hJ',
        ]
        secret_values[-1] = secrets.token_hex(20)
        high_entropy_31 = secrets.token_urlsafe(24)[:31]
        path_token_one = ''.join(secrets.choice('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789') for _ in range(40))
        path_token_two = ''.join(secrets.choice('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789') for _ in range(40))
        path_secrets = [('/api/webhooks/123456/' + path_token_one, path_token_one),
                        ('/Us' + 'ers/me/.config/tokens/' + path_token_two, path_token_two)]
        ordinary = ['extraordinarywordwithoutspaces', '/tmp/project/Sources/ChatSession.swift',
                    '這是一句不應遮蔽的中文原話', 'a' * 40]
        tagged = ['<system-reminder>REMINDER_LOWER</system-reminder>',
                  '<SYSTEM-REMINDER>REMINDER_UPPER</SYSTEM-REMINDER>',
                  '<System-Reminder/>', '<system-reminder />']
        base_text = '安全檢查 ' + ' '.join(secret_values + [high_entropy_31] + [path for path, _ in path_secrets] + ordinary + tagged)
        tx.write_text(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': base_text}}, ensure_ascii=False) + '\n', encoding='utf-8')

        def tree_signature(path):
            if not path.exists():
                return None
            return tuple((str(p.relative_to(path)), p.lstat().st_mode, p.lstat().st_size, p.lstat().st_mtime_ns)
                         for p in sorted([path, *path.rglob('*')], key=str))
        formal_before = tree_signature(formal)

        def call(sub, payload, *, compact_dir=True, home_dir=home):
            out = io.StringIO()
            env = {'HOME': str(home_dir)}
            if compact_dir:
                env['CODENV_COMPACT_DIR'] = str(cdir)
            with patch.dict(os.environ, env, clear=False), \
                 patch.object(sys, 'stdin', io.StringIO(json.dumps(payload, ensure_ascii=False))), \
                 contextlib.redirect_stdout(out):
                if not compact_dir:
                    os.environ.pop('CODENV_COMPACT_DIR', None)
                rc = cg.main(['compact-guard.py', sub])
            return SimpleNamespace(returncode=rc, stdout=out.getvalue())

        def context_for(sid, compact_dir=True, home_dir=home):
            r = call('session-start', {'session_id': sid, 'source': 'compact'}, compact_dir=compact_dir, home_dir=home_dir)
            assert r.returncode == 0, (sid, r.returncode, r.stdout)
            if not r.stdout:
                return ''
            return json.loads(r.stdout)['hookSpecificOutput']['additionalContext']

        checks = []
        def checked(name, fn):
            try:
                fn()
                checks.append((name, True, ''))
            except Exception as exc:
                checks.append((name, False, str(exc)))

        def security_outputs():
            result = call('pre-compact', {'session_id': 'security', 'transcript_path': str(tx)}, home_dir=home)
            assert result.returncode == 0, f'輸入=session_id security；預期=pre-compact exit 0；實際={result.returncode}, stdout={result.stdout!r}'
            saved = '\n'.join(p.read_text(encoding='utf-8', errors='replace') for p in cdir.rglob('*') if p.is_file())
            return saved, context_for('security')

        def check_secrets():
            saved, context = security_outputs()
            issues = []
            formats = [
                ('sk- 開頭', [secret_values[0]]),
                ('nvapi- 開頭', [secret_values[1]]),
                ('ghp_ 開頭', [secret_values[2]]),
                ('Authorization: Bearer（大小寫混合）', secret_values[3:5]),
                ('長隨機高熵字串', [secret_values[5]]),
                ('webhook 路徑後 40 字元隨機段', [path_secrets[0][1]]),
                ('token 路徑後 40 字元隨機段', [path_secrets[1][1]]),
            ]
            for label, variants in formats:
                format_issues = []
                for secret in variants:
                    for name, output in [('快照檔', saved), ('additionalContext', context)]:
                        if secret in output:
                            format_issues.append(f'輸入={secret!r}；預期={name} 不含原文；實際={name} 含原文')
                print(f'  金鑰格式 {label}：{"失敗" if format_issues else "通過"}')
                for issue in format_issues:
                    print('    ' + issue)
                issues.extend(format_issues)
            print(f'  金鑰格式 31 字元高熵觀察（不判定）：原文在快照={high_entropy_31 in saved}，在 additionalContext={high_entropy_31 in context}')
            assert not issues, '\n'.join(issues)

        def check_ordinary():
            saved, context = security_outputs()
            for text in ordinary:
                assert text in saved and text in context, f'輸入={text!r}；預期=快照檔與 additionalContext 保留原文；實際=快照含 {text in saved}, additionalContext 含 {text in context}'

        def check_tags():
            _, context = security_outputs()
            for marker in ('REMINDER_LOWER', 'REMINDER_UPPER', '<System-Reminder/>', '<system-reminder />'):
                assert marker.lower() not in context.lower(), f'輸入={marker!r}；預期=additionalContext 不含系統標籤／內容；實際={context!r}'

        def check_ids():
            ids = ['../../x', 'a/b', '', 'L' * 200, '中文識別', '含 空白!@#$%^&()']
            for i, sid in enumerate(ids):
                before = set(temp.rglob('*'))
                one_tx = temp / f'id-{i}.jsonl'
                one_tx.write_text(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': f'ID_PAYLOAD_{i}'}}, ensure_ascii=False) + '\n', encoding='utf-8')
                result = call('pre-compact', {'session_id': sid, 'transcript_path': str(one_tx)}, home_dir=home)
                after = set(temp.rglob('*'))
                outside = [p for p in after - before if p != cdir and cdir not in p.parents and p != one_tx]
                assert result.returncode == 0 and not outside, f'輸入=session_id={sid!r}；預期=exit 0 且新增檔案留在 {cdir}；實際=exit {result.returncode}, 逃出檔案={outside}'
            for sid, payload in [('a/b', 'PAYLOAD_SLASH'), ('ab', 'PAYLOAD_PLAIN')]:
                one_tx = temp / ('collision-' + ('slash' if '/' in sid else 'plain') + '.jsonl')
                one_tx.write_text(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': payload}}, ensure_ascii=False) + '\n', encoding='utf-8')
                result = call('pre-compact', {'session_id': sid, 'transcript_path': str(one_tx)}, home_dir=home)
                assert result.returncode == 0, f'輸入=session_id={sid!r}；預期=pre-compact exit 0；實際={result.returncode}'
            slash_ctx, plain_ctx = context_for('a/b'), context_for('ab')
            assert 'PAYLOAD_SLASH' in slash_ctx and 'PAYLOAD_PLAIN' not in slash_ctx, f'輸入=session_id=a/b；預期=只讀 PAYLOAD_SLASH；實際={slash_ctx!r}'
            assert 'PAYLOAD_PLAIN' in plain_ctx and 'PAYLOAD_SLASH' not in plain_ctx, f'輸入=session_id=ab；預期=只讀 PAYLOAD_PLAIN；實際={plain_ctx!r}'

        default_home = temp / 'default-home'
        default_tx = temp / 'default.jsonl'
        default_tx.write_text(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': 'DEFAULT_HOME_PAYLOAD'}}) + '\n', encoding='utf-8')
        default_dir = default_home / 'Library' / 'Application Support' / 'AI 工作台' / 'compact-state'
        def check_default():
            result = call('pre-compact', {'session_id': 'default-session', 'transcript_path': str(default_tx)}, compact_dir=False, home_dir=default_home)
            assert result.returncode == 0 and default_dir.is_dir() and any(default_dir.iterdir()), f'輸入=未設定 CODENV_COMPACT_DIR、HOME={default_home}；預期=寫入 {default_dir}；實際=exit {result.returncode}, 目錄存在={default_dir.is_dir()}'
            context = context_for('default-session', compact_dir=False, home_dir=default_home)
            assert 'DEFAULT_HOME_PAYLOAD' in context, f'輸入=session_id=default-session；預期=additionalContext 保留 DEFAULT_HOME_PAYLOAD；實際={context!r}'
            actual = tree_signature(formal)
            assert actual == formal_before, f'輸入=測試 HOME 預設資料夾情境；預期=正式路徑狀態不變；實際 before={formal_before!r}, after={actual!r}'

        long_tx = temp / 'long.jsonl'
        long_rows = [{'type': 'user', 'message': {'role': 'user', 'content': f'舊對話{i} ' + ('字' * 5000)}} for i in range(5)]
        long_rows.append({'type': 'user', 'message': {'role': 'user', 'content': '最後一句MUST_KEEP_FINAL'}})
        long_tx.write_text('\n'.join(json.dumps(row, ensure_ascii=False) for row in long_rows) + '\n', encoding='utf-8')
        def check_limit():
            result = call('pre-compact', {'session_id': 'long-session', 'transcript_path': str(long_tx)}, home_dir=home)
            assert result.returncode == 0, f'輸入=長對話；預期=pre-compact exit 0；實際={result.returncode}'
            context = context_for('long-session')
            assert len(context) <= 12000, f'輸入=長對話；預期=additionalContext <= 12,000 字元；實際={len(context)}'
            assert 'MUST_KEEP_FINAL' in context, f'輸入=最後一句原話；預期=保留 MUST_KEEP_FINAL；實際尾端={context[-500:]!r}'

        checked('規格 1 金鑰不得外流', check_secrets)
        checked('規格 2 不誤遮', check_ordinary)
        checked('規格 3 系統標籤移除', check_tags)
        checked('規格 4 session ID 路徑與隔離', check_ids)
        checked('規格 5 預設資料夾與正式路徑未變', check_default)
        checked('規格 6 注入上限與末句保留', check_limit)
        for name, passed, detail in checks:
            print(f'{name}：{"通過" if passed else "失敗"}')
            if detail:
                print('  ' + detail.replace('\n', '\n  '))
        outer_env_patch.stop()
        if not all(passed for _, passed, _ in checks):
            raise SystemExit(1)
    else:
        raise AssertionError('未知案例：' + case)
print('斷言通過 ' + case)
