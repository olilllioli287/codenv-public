"""隔離載入實際 CLI；不執行 main，不呼叫 App／agy／網路。"""
import importlib.machinery
import importlib.util
import os
from pathlib import Path
import subprocess
import time
from types import SimpleNamespace
from unittest.mock import patch


def forbidden(*args, **kwargs):
    raise AssertionError('測試禁止外部程序／網路')


def load(root, temp):
    os.environ['CODENV_COLLAB_FILE'] = str(temp / 'collab.json')
    loader = importlib.machinery.SourceFileLoader('exam_todo', str(root / 'scripts/codenv-todo'))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    m = importlib.util.module_from_spec(spec)
    with patch.object(subprocess, 'Popen', forbidden):
        loader.exec_module(m)
    m.subprocess.Popen = forbidden
    m.urllib.request.urlopen = forbidden
    m.say = lambda *a: None
    m.RUNS = str(temp / 'agy-runs')
    Path(m.RUNS).mkdir()
    return m


def finish(m, temp, out, err='', log='', code=0, jump=0, clock=time.monotonic):
    """jump：結束前把牆鐘往前撥幾秒（模擬 Mac 睡過去）；clock：執行器記開始時間用的時鐘（現在是單調時鐘）"""
    r = m.AgyRunner()
    r.sid, r.owner = 'aaaaaa', 'gemini3.8flash'
    r.proc = SimpleNamespace(returncode=code)
    r.started = clock() - 1
    r.count_date = '2026-11-04'
    r.log = lambda *a: None
    r.files = tuple(str(temp / name) for name in ('out', 'err', 'agy', 'result', 'runlog'))
    for p, text in zip(r.files[:3], [out, err, log]):
        Path(p).write_text(text)
    final, step, refunds = [], {'state': 'doing'}, []
    r.update_step = lambda sid, fn: fn({}, step)
    r.set_final = lambda *args, **kw: final.append((args, kw))
    m.refund = lambda *args: refunds.append(args)
    real = time.time
    time.time = lambda: real() + jump
    try:
        r.finish()
    finally:
        time.time = real
    assert len(final) == 1, final
    return final[0][0], step, refunds
