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
    else:
        raise AssertionError('未知案例：' + case)
print('斷言通過 ' + case)
