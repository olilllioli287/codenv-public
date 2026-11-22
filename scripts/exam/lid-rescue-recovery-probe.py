#!/usr/bin/env python3
"""Compare multi-process rescue recovery observations with the exam contract."""
import json
import sys
from pathlib import Path


def compare(expected, actual, path):
    errors = []
    if isinstance(expected, dict):
        if set(expected) == {"$notContains"}:
            forbidden = expected["$notContains"]
            if not isinstance(actual, list):
                return [f"{path}: 預期 list 以排除項目，實際 {actual!r}"]
            if not isinstance(forbidden, list):
                return [f"{path}: $notContains 必須是 list"]
            return [f"{path}: 不得包含 {item!r}" for item in forbidden if item in actual]
        if set(expected) == {"$atMost"}:
            limit = expected["$atMost"]
            if type(actual) is not int or actual > limit:
                return [f"{path}: 預期整數至多 {limit}，實際 {actual!r}"]
            return errors
        if not isinstance(actual, dict):
            return [f"{path}: 預期 object，實際 {actual!r}"]
        for key, value in expected.items():
            errors.extend(compare(value, actual.get(key), f"{path}.{key}"))
    elif isinstance(expected, list):
        if not isinstance(actual, list) or len(actual) != len(expected):
            return [f"{path}: 預期 {expected!r}，實際 {actual!r}"]
        for index, (want, got) in enumerate(zip(expected, actual)):
            errors.extend(compare(want, got, f"{path}[{index}]"))
    elif type(expected) is not type(actual) or expected != actual:
        errors.append(f"{path}: 預期 {expected!r}，實際 {actual!r}")
    return errors


def c418_preservation_errors(contract, root):
    """Check message IDs and literal text across every successful automatic send phase."""
    errors = []
    spec = contract["C418"]
    scenarios = spec["simulation"]["scenarios"]
    for scenario_name, scenario in scenarios.items():
        phases = scenario["phases"]
        actions = scenario["phaseActions"]
        first_action = actions[phases[0]]
        chat_id = first_action["selectedChatID"]
        messages = {}
        for message in first_action.get("initialOutbox", []):
            messages[message["messageID"]] = message
        for action in actions.values():
            message = action.get("addAfterSecondClose")
            if message:
                messages[message["messageID"]] = message

        id_counts = {message_id: 0 for message_id in messages}
        text_counts = {message_id: 0 for message_id in messages}
        marker_counts = {message_id: 0 for message_id in messages}
        final_observed = None
        for phase in phases:
            output_file = root / scenario_name / f"{phase}.json"
            try:
                data = json.loads(output_file.read_text())
            except (OSError, json.JSONDecodeError):
                continue  # The phase comparator reports the missing or malformed output.
            observed = data.get("observed")
            if not isinstance(observed, dict):
                continue
            final_observed = observed
            attempts = observed.get("automatedSendAttempts")
            if not isinstance(attempts, list):
                errors.append(f"{scenario_name}/{phase}.automatedSendAttempts: 必須輸出自動送出清單")
                continue
            for index, attempt in enumerate(attempts):
                location = f"{scenario_name}/{phase}.automatedSendAttempts[{index}]"
                if not isinstance(attempt, dict):
                    errors.append(f"{location}: 預期 object")
                    continue
                if attempt.get("didSend") is not True:
                    continue
                message_ids = attempt.get("messageIDs")
                if not isinstance(message_ids, list) or any(not isinstance(message_id, str) for message_id in message_ids):
                    errors.append(f"{location}.messageIDs: 成功的自動送出必須列出訊息 ID")
                    continue
                tracked_ids = [message_id for message_id in message_ids if message_id in messages]
                if tracked_ids:
                    if attempt.get("recipientChatID") != chat_id:
                        errors.append(f"{location}.recipientChatID: M1/M2 必須送給 {chat_id}")
                    if attempt.get("source") not in {"闔蓋繼續", "闔蓋中斷"}:
                        errors.append(f"{location}.source: 必須是闔蓋繼續或闔蓋中斷自動送出")
                text = attempt.get("text")
                if not isinstance(text, str):
                    errors.append(f"{location}.text: 成功的自動送出必須輸出實際文字")
                    continue
                for message_id, message in messages.items():
                    id_counts[message_id] += message_ids.count(message_id)
                    text_counts[message_id] += text.count(message.get("text", ""))
                    marker = message.get("imageMarker")
                    if marker:
                        marker_counts[message_id] += text.count(marker)

        for message_id, message in messages.items():
            if message_id == "M1":
                if id_counts[message_id] != 1:
                    errors.append(f"{scenario_name}.M1: 所有成功自動送出中的 ID 須恰 1 次，實際 {id_counts[message_id]}")
                if text_counts[message_id] != 1:
                    errors.append(f"{scenario_name}.M1: 原文在所有成功自動送出中須恰 1 次，實際 {text_counts[message_id]}")
                if message.get("imageMarker") and marker_counts[message_id] != 1:
                    errors.append(f"{scenario_name}.M1: 圖片標記在所有成功自動送出中須恰 1 次，實際 {marker_counts[message_id]}")
            elif message_id == "M2" and id_counts[message_id] > 0:
                if text_counts[message_id] < id_counts[message_id]:
                    errors.append(
                        f"{scenario_name}.M2: 每次成功送出均須包含原文，ID 次數 {id_counts[message_id]}、原文次數 {text_counts[message_id]}"
                    )

        cumulative = final_observed.get("cumulative") if isinstance(final_observed, dict) else None
        if not isinstance(cumulative, dict):
            errors.append(f"{scenario_name}.cumulative: 最終 phase 必須輸出跨 phase 計數")
            continue
        for message_id, field in (("M1", "m1DeliveryCount"), ("M2", "m2DeliveryCount")):
            if message_id not in messages:
                continue
            actual_count = cumulative.get(field)
            if type(actual_count) is not int or actual_count != id_counts[message_id]:
                errors.append(f"{scenario_name}.cumulative.{field}: 須等於所有成功自動送出中的 ID 次數 {id_counts[message_id]}，實際 {actual_count!r}")

        final_outbox_ids = final_observed.get("outboxMessageIDs")
        if not isinstance(final_outbox_ids, list):
            errors.append(f"{scenario_name}.outboxMessageIDs: 最終 phase 必須輸出寄件匣訊息 ID 清單")
            continue
        if "M1" in messages and "M1" in final_outbox_ids:
            errors.append(f"{scenario_name}.outboxMessageIDs: M1 已送達後不得留在寄件匣")
        if "M2" in messages:
            m2_was_sent = id_counts["M2"] > 0 and text_counts["M2"] >= id_counts["M2"]
            if "M2" not in final_outbox_ids and not m2_was_sent:
                errors.append(f"{scenario_name}.M2: 不得遺失，必須仍在寄件匣或已成功自動送出")
    return errors


def main():
    if len(sys.argv) != 4:
        print("用法：lid-rescue-recovery-probe.py <C415|C416|C417|C418> <contract.json> <輸出根目錄>")
        return 2
    case_id, contract_path, output_root = sys.argv[1:]
    contract = json.loads(Path(contract_path).read_text())
    root = Path(output_root)
    expected = contract[case_id]["expected"]["scenarios"]
    errors = []

    for scenario, scenario_expected in expected.items():
        phase_expectations = scenario_expected["phases"]
        phase_names = list(phase_expectations)
        if not phase_names:
            errors.append(f"{scenario}: 沒有 phase 斷言")
            continue
        last_observed = None
        for phase, phase_expected in phase_expectations.items():
            output_file = root / scenario / f"{phase}.json"
            try:
                data = json.loads(output_file.read_text())
            except (OSError, json.JSONDecodeError) as error:
                errors.append(f"{scenario}/{phase}: 無法讀取掛鉤輸出：{error}")
                continue
            for key, value in {
                "schemaVersion": 1,
                "caseId": case_id,
                "scenario": scenario,
                "phase": phase,
            }.items():
                errors.extend(compare(value, data.get(key), f"{scenario}/{phase}.{key}"))
            observed = data.get("observed")
            if isinstance(observed, dict) and observed.get("probeError"):
                errors.append(f"{scenario}/{phase}.probeError: 掛鉤執行失敗：{observed['probeError']}")
                last_observed = observed
                continue
            errors.extend(compare(phase_expected, observed, f"{scenario}/{phase}.observed"))
            last_observed = observed

        cumulative_expected = scenario_expected.get("cumulative")
        if cumulative_expected is not None:
            cumulative_actual = last_observed.get("cumulative") if isinstance(last_observed, dict) else None
            if not (isinstance(last_observed, dict) and last_observed.get("probeError")):
                errors.extend(compare(cumulative_expected, cumulative_actual, f"{scenario}.cumulative"))

    if case_id == "C418":
        errors.extend(c418_preservation_errors(contract, root))

    for error in errors:
        print("失敗：" + error)
    if not errors:
        print(f"通過：{case_id} 多程序救援重開情境")
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
