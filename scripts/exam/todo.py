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
    else:
        raise AssertionError('未知案例：' + case)
print('斷言通過 ' + case)
