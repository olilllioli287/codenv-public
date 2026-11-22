#!/usr/bin/env python3
"""07-28 探針用的假 Claude：回合結束後還有背景工作／背景子代理在動。

用法：codenv 測試版加 --chat-claude <這個檔>，在聊天框送出下列指令字：
  BG-A  回合立刻結束（result），1 秒後回報背景工作 1 件，2 秒後背景子代理（有 parent_tool_use_id）繼續吐 stream_event／assistant，
        背景子代理一直吐到第 14 秒；背景工作到第 16 秒才完成但不叫醒（情境 a：只有「完成」＋「背景工作 1 件」，沒有「正在處理」）。
  BG-B  回合結束後 1 秒回報背景工作 1 件；4 秒後背景工作完成，送 task_notification 並叫醒新的一輪（新的回覆「第二輪回覆」，約 3 秒後 result）
        （情境 b：叫醒後出現新的「正在處理」與新回覆，結束後消失）。
  其他  單純回一則「ok」就 result。
"""
import json
import sys
import threading
import time
import uuid

lock = threading.Lock()


def emit(obj):
    with lock:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def text_turn(text, parent=None, session=None):
    mid = "msg-" + str(uuid.uuid4())
    extra = {"parent_tool_use_id": parent} if parent else {}
    emit({"type": "stream_event", "event": {"type": "message_start", "message": {"id": mid, "type": "message", "role": "assistant", "content": []}}, "api_message_id": mid, **extra})
    emit({"type": "stream_event", "event": {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}, "api_message_id": mid, **extra})
    emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}}, "api_message_id": mid, **extra})
    emit({"type": "stream_event", "event": {"type": "content_block_stop", "index": 0}, "api_message_id": mid, **extra})
    emit({"type": "assistant", "message": {"id": mid, "type": "message", "role": "assistant", "model": "claude-test", "content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "usage": {"input_tokens": 1, "output_tokens": 1}}, **extra})


def result():
    emit({"type": "result", "subtype": "success", "is_error": False, "duration_ms": 1000, "result": "", "session_id": "fake"})


def bg(tasks):
    emit({"type": "system", "subtype": "background_tasks_changed", "tasks": tasks})


TASK = {"task_id": "bgfake1", "task_type": "local_bash", "description": "假背景工作", "command": "sleep 99"}


def later(sec, fn):
    t = threading.Timer(sec, fn)
    t.daemon = True
    t.start()


def scenario_a():
    text_turn("第一輪回覆（回合已完成）")
    result()
    later(1, lambda: bg([TASK]))
    for i in range(2, 14, 2):
        later(i, lambda i=i: text_turn(f"背景子代理 {i} 秒的輸出", parent="toolu_fakeagent"))
    later(16, lambda: bg([]))


def scenario_b():
    text_turn("第一輪回覆（回合已完成）")
    result()
    later(1, lambda: bg([TASK]))

    def wake():
        emit({"type": "system", "subtype": "task_notification", "task_id": "bgfake1", "status": "completed", "summary": "假背景工作完成"})
        emit({"type": "user", "message": {"role": "user", "content": "<task-notification><summary>假背景工作完成</summary><status>completed</status></task-notification>"}})
        bg([])
        text_turn("第二輪回覆（背景工作叫醒的新回合）")
        later(3, result)
    later(4, wake)


def main():
    for line in sys.stdin:
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue
        if req.get("type") == "control_request":
            if (req.get("request") or {}).get("subtype") == "initialize":
                emit({"type": "control_response", "response": {"request_id": req.get("request_id"), "subtype": "success"}})
            continue
        if req.get("type") != "user":
            continue
        content = (req.get("message") or {}).get("content") or []
        text = content if isinstance(content, str) else "".join(b.get("text", "") for b in content if isinstance(b, dict))
        if req.get("uuid"):
            emit({"type": "user", "uuid": req["uuid"], "isReplay": True, "message": {"role": "user", "content": content}})
        if "BG-A" in text:
            scenario_a()
        elif "BG-B" in text:
            scenario_b()
        else:
            text_turn("ok")
            result()
    return 0


if __name__ == "__main__":
    sys.exit(main())
