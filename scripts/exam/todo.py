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
    else:
        raise AssertionError('未知案例：' + case)
print('斷言通過 ' + case)
