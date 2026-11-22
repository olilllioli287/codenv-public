#!/usr/bin/env python3
"""00.07.01 考題用的假 Claude（stream-json）。

用法：codenv 測試版加 --chat-claude <包這個檔的 wrapper>；wrapper 把記錄資料夾當第一個參數：
  #!/bin/sh
  exec python3 <這個檔> <記錄資料夾>
每個聊天室一份記錄 <記錄資料夾>/<CODENV_CONVERSATION>.log，每行是收到的原始 stdin JSON（加一行 #pid=…），
方便考題數「收到幾個 interrupt 控制請求、有沒有 send_now、收到哪些訊息」。

訊息文字裡的指令（可多個，出現在 user 訊息任何位置）：
  [[SLOW:秒:文字]]   開一輪、先不輸出任何東西（卡住情境），過「秒」秒後輸出「文字」並 result 成功。
                      這一輪進行中收到 control_request interrupt：預設立刻吐「[Request interrupted by user]」is_error result 結束這輪；
                      若指令寫成 [[SLOW!:秒:文字]]（驚嘆號）＝忽略 interrupt（模擬中斷沒生效），照常等到時間到。
  [[SLOWI!:秒:文字]] 開一輪、忽略所有 interrupt（同 SLOW!），但計時從「收到第一個 interrupt」起算：收到後過「秒」秒才輸出「文字」並 result 成功
                      （考「監督器中斷後、旗標期限剛過才到的 result」用；沒收到 interrupt 就一直不結束）。每個收到的 interrupt 另寫一行 #interrupt-at <epoch 秒>。
  [[OK:文字]]        立刻輸出「文字」並 result 成功。
  [[ERR:文字]]       立刻 result is_error=true（subtype error_during_execution、result 欄位為「文字」），沒有任何 assistant 回答。
  [[INTR]]           立刻吐 [Request interrupted by user] 的 is_error result（模擬使用者按 ESC／stop 後的結果，沒有真的收到 interrupt）。
  沒有指令            立刻回「ok」並 result。
這一輪進行中又收到 user 訊息（steer／補充）：不另開一輪、不多吐 result（視為併入目前這輪），只寫進記錄。
"""
import json
import os
import re
import sys
import threading
import time

LOGDIR = sys.argv[1] if len(sys.argv) > 1 else "/private/tmp"
CONV = os.environ.get("CODENV_CONVERSATION") or str(os.getpid())
LOG = os.path.join(LOGDIR, CONV + ".log")
lock = threading.Lock()
state = {"active": False, "timer": None, "ignore_int": False, "turn": 0, "after_int": None, "after_text": ""}


def log(line):
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line.rstrip("\n") + "\n")


def emit(obj):
    with lock:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def text_turn(text):
    mid = "msg-%d-%d" % (os.getpid(), time.time_ns())
    emit({"type": "stream_event", "event": {"type": "message_start", "message": {"id": mid, "type": "message", "role": "assistant", "content": []}}, "api_message_id": mid})
    emit({"type": "stream_event", "event": {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}, "api_message_id": mid})
    emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}}, "api_message_id": mid})
    emit({"type": "stream_event", "event": {"type": "content_block_stop", "index": 0}, "api_message_id": mid})
    emit({"type": "assistant", "message": {"id": mid, "type": "message", "role": "assistant", "model": "claude-test", "content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "usage": {"input_tokens": 1, "output_tokens": 1}}})


def ok_result(text=""):
    # 真 Claude 的成功 result 會帶最後回答全文；摘要類考題（舊結論沿用）需要它
    emit({"type": "result", "subtype": "success", "is_error": False, "duration_ms": 1000, "result": text, "session_id": "fake"})


def err_result(text):
    emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "duration_ms": 1000, "result": text, "session_id": "fake"})


def finish_ok(text):
    with lock:
        if not state["active"]:
            return
        state["active"] = False
    log("#turn-finished-ok " + text)
    text_turn(text)
    ok_result(text)


def interrupted():
    log("#turn-interrupted")
    text_turn("[Request interrupted by user]")
    err_result("[Request interrupted by user]")


def user_text(req):
    content = (req.get("message") or {}).get("content") or []
    return content if isinstance(content, str) else "".join(b.get("text", "") for b in content if isinstance(b, dict))


def start_turn(text):
    state["after_int"] = None
    state["timer"] = None
    m = re.search(r"\[\[SLOWI!:(\d+(?:\.\d+)?):(.*?)\]\]", text, re.S)
    if m:
        state["active"] = True
        state["ignore_int"] = True
        state["after_int"] = float(m.group(1))
        state["after_text"] = m.group(2)
        return
    m = re.search(r"\[\[(SLOW!?):(\d+(?:\.\d+)?):(.*?)\]\]", text, re.S)
    if m:
        state["active"] = True
        state["ignore_int"] = m.group(1) == "SLOW!"
        t = threading.Timer(float(m.group(2)), finish_ok, args=(m.group(3),))
        t.daemon = True
        state["timer"] = t
        t.start()
        return
    m = re.search(r"\[\[OK:(.*?)\]\]", text, re.S)
    if m:
        text_turn(m.group(1))
        ok_result(m.group(1))
        return
    m = re.search(r"\[\[ERR:(.*?)\]\]", text, re.S)
    if m:
        err_result(m.group(1))
        return
    if "[[INTR]]" in text:
        interrupted()
        return
    text_turn("ok")
    ok_result("ok")


def main():
    log("#pid=%d start" % os.getpid())
    for line in sys.stdin:
        log(line)
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = req.get("type")
        if kind == "control_request":
            sub = (req.get("request") or {}).get("subtype")
            emit({"type": "control_response", "response": {"request_id": req.get("request_id"), "subtype": "success"}})
            if sub == "interrupt":
                log("#interrupt-at %.3f" % time.time())
                with lock:
                    if state["active"] and state["after_int"] is not None and state["timer"] is None:
                        t = threading.Timer(state["after_int"], finish_ok, args=(state["after_text"],))
                        t.daemon = True
                        state["timer"] = t
                        t.start()
                with lock:
                    was_active = state["active"]
                    ignore = state["ignore_int"]
                    if was_active and not ignore:
                        state["active"] = False
                        if state["timer"]:
                            state["timer"].cancel()
                if was_active and not ignore:
                    interrupted()
            continue
        if kind != "user":
            continue
        text = user_text(req)
        if req.get("uuid"):
            emit({"type": "user", "uuid": req["uuid"], "isReplay": True, "message": {"role": "user", "content": (req.get("message") or {}).get("content")}})
        with lock:
            busy = state["active"]
        if busy:
            log("#merged-into-active-turn " + text[:80].replace("\n", " "))
            continue
        start_turn(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
