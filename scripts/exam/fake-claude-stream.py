#!/usr/bin/env python3
"""C17 用的假 Claude：串流回答，同時預先寫入完整歷史以覆蓋重載競態。"""

import json
import os
import sys
import time
import uuid


ANSWER = "串流考題C17-唯一字串"


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def append_record(path, obj):
    with open(path, "a", encoding="utf-8") as transcript:
        transcript.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
        transcript.flush()


def argument_value(args, name):
    try:
        return args[args.index(name) + 1]
    except (ValueError, IndexError):
        return None


def main():
    args = sys.argv[1:]
    session_id = argument_value(args, "--session-id") or argument_value(args, "--resume")
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    if not session_id or not config_dir:
        print("假 Claude 缺少 --session-id/--resume 或 CLAUDE_CONFIG_DIR", file=sys.stderr)
        return 2
    try:
        session_id = str(uuid.UUID(session_id))
    except ValueError:
        print("假 Claude 收到無效的 session UUID", file=sys.stderr)
        return 2

    cwd = os.environ.get("AI_WORKBENCH_TEST_CWD", os.getcwd())
    slug = "".join(c if c.isascii() and c.isalnum() else "-" for c in cwd)
    transcript_dir = os.path.join(config_dir, "projects", slug)
    os.makedirs(transcript_dir, exist_ok=True)
    transcript_path = os.path.join(transcript_dir, session_id + ".jsonl")

    for line in sys.stdin:
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue

        if request.get("type") == "control_request":
            req = request.get("request") or {}
            if req.get("subtype") == "initialize":
                emit({
                    "type": "control_response",
                    "response": {
                        "request_id": request.get("request_id"),
                        "subtype": "success",
                    },
                })
            continue

        if request.get("type") != "user":
            continue

        message = request.get("message") or {}
        content = message.get("content") or []
        message_uuid = request.get("uuid") or str(uuid.uuid4())
        user_record = {
            "type": "user",
            "uuid": message_uuid,
            "sessionId": session_id,
            "cwd": cwd,
            "message": {"role": "user", "content": content},
        }

        # 先回送原 UUID，讓 ChatSession 將原生輸入泡泡標記為已送達。
        emit({**user_record, "isReplay": True})
        append_record(transcript_path, user_record)

        message_id = "msg-c17-" + str(uuid.uuid4())
        assistant_record = {
            "type": "assistant",
            "sessionId": session_id,
            "cwd": cwd,
            "message": {
                "id": message_id,
                "type": "message",
                "role": "assistant",
                "model": "claude-test",
                "content": [{"type": "text", "text": ANSWER}],
                "stop_reason": "end_turn",
                "stop_sequence": None,
                "usage": {"input_tokens": 1, "output_tokens": len(ANSWER)},
            },
        }
        # 先把完整回覆落到歷史，再送串流，刻意讓 loadHistory 和 queued 事件重疊。
        append_record(transcript_path, assistant_record)

        emit({
            "type": "stream_event",
            "event": {
                "type": "message_start",
                "message": {"id": message_id, "type": "message", "role": "assistant", "content": []},
            },
            "api_message_id": message_id,
        })
        emit({
            "type": "stream_event",
            "event": {
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "text", "text": ""},
            },
            "api_message_id": message_id,
        })
        parts = [ANSWER[i * len(ANSWER) // 10:(i + 1) * len(ANSWER) // 10] for i in range(10)]
        for part in parts:
            time.sleep(0.5)
            emit({
                "type": "stream_event",
                "event": {
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": {"type": "text_delta", "text": part},
                },
                "api_message_id": message_id,
            })
        emit({
            "type": "stream_event",
            "event": {"type": "content_block_stop", "index": 0},
            "api_message_id": message_id,
        })
        emit({
            "type": "stream_event",
            "event": {"type": "message_stop"},
            "api_message_id": message_id,
        })
        emit(assistant_record)
        # 完整回答送出後先等一下才結束這輪：考題要趁這段時間（格子還在、還在忙）讀畫面；
        # 結束後不在版面上的閒置格子會被整格收掉（Workspace.releaseUnplaced），就看不到了
        time.sleep(float(os.environ.get("FAKE_RESULT_DELAY", "75")))
        emit({"type": "result", "subtype": "success", "is_error": False, "result": ANSWER})

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
