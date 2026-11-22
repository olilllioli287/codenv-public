#!/usr/bin/env python3
"""Validate normalized observations for the e74b99b draft lifecycle exam.

TODO(e74b99b): adapt TestHarness output to this normalized observation schema when
施工-codex publishes the hook contract. Do not invent app launch flags here.

For C436, the normalized observation contract is provisional: multiple redact
workers must overlap with 1,000 main-thread rounds that each exercise allow,
reloadLearning, and removeLearnedFeature. A Thread Sanitizer run is recommended
by the specification, but is reported separately from the required no-crash check.
"""
import json
import sys
from pathlib import Path

MIB = 1024 * 1024


def errors_for(case_id, observed, recovery_observed=None):
    errors = []

    def check(path, condition, message):
        if not condition:
            errors.append(f"{path}: {message}")

    if not isinstance(observed, dict):
        return ["observed: 預期 JSON object"]

    if case_id == "C431":
        size = observed.get("draftSizeBytes")
        check("draftSizeBytes", type(size) is int and 0 <= size < MIB, "必須小於 1 MiB")
        check("saveMode", observed.get("saveMode") == "synchronous", "小草稿須同步存檔")
        check("saveCompletedBeforeReturn", observed.get("saveCompletedBeforeReturn") is True, "返回前必須已完成持久化")
        check("reopenedContentMatches", observed.get("reopenedContentMatches") is True, "重開後內容須與來源相同")
    elif case_id in {"C432", "C433"}:
        # Snapshot checks belong to the end-event observation, before the next
        # launch restores the data and may consume/clear the recovery file.
        size = observed.get("draftSizeBytes")
        check("prepare.draftSizeBytes", type(size) is int and size >= MIB, "必須至少 1 MiB")
        check("prepare.saveMode", observed.get("saveMode") == "background", "大草稿須背景存檔")
        check("prepare.writeIncompleteAtEnd", observed.get("writeIncompleteAtEnd") is True, "需覆蓋結束／關格時背景寫入未完成")
        expected_end_event = "applicationTermination" if case_id == "C432" else "paneClose"
        check("prepare.endEvent", observed.get("endEvent") == expected_end_event, f"須測試 {expected_end_event}")
        check("prepare.endEventCancelled", observed.get("endEventCancelled") is False, "結束／關格不得被取消")
        check("prepare.maskedSnapshotSaved", observed.get("maskedSnapshotSaved") is True, "復原前須觀察到遮罩快照已寫入")
        check("prepare.snapshotIsolated", observed.get("snapshotIsolated") is True, "復原前快照位置須確認在隔離路徑")
        check("prepare.snapshotContainsRawFakeCredential", observed.get("snapshotContainsRawFakeCredential") is False, "復原前快照不得含假金鑰原文")
        if not isinstance(recovery_observed, dict):
            errors.append("inspect: 預期下次啟動讀回復原資料後的 JSON")
        else:
            check("inspect.nextLaunchNotice", recovery_observed.get("nextLaunchNotice") is True, "下次啟動讀回時須提示未完成草稿")
    elif case_id == "C434":
        size = observed.get("draftSizeBytes")
        check("draftSizeBytes", type(size) is int and size >= MIB, "須用大草稿情境")
        within = observed.get("withinDeadline")
        timeout = observed.get("timeout")
        if not isinstance(within, dict):
            errors.append("withinDeadline: 預期 object")
        else:
            elapsed = within.get("elapsedMs")
            check("withinDeadline.elapsedMs", type(elapsed) is int and 0 <= elapsed <= 2000, "交接等待不得超過 2 秒")
            check("withinDeadline.handoffSucceeded", within.get("handoffSucceeded") is True, "期限內完成須交接成功")
            check("withinDeadline.destinationMatches", within.get("destinationMatches") is True, "目的草稿須收到內容")
        if not isinstance(timeout, dict):
            errors.append("timeout: 預期 object")
        else:
            elapsed = timeout.get("elapsedMs")
            check("timeout.elapsedMs", type(elapsed) is int and 0 <= elapsed <= 2000, "逾時決定須在 2 秒內返回")
            check("timeout.handoffSucceeded", timeout.get("handoffSucceeded") is False, "逾時交接須失敗")
            check("timeout.sourceUnchanged", timeout.get("sourceUnchanged") is True, "來源草稿須原樣保留")
    elif case_id == "C435":
        source = observed.get("source")
        destination = observed.get("destination")
        if not isinstance(source, dict) or not isinstance(destination, dict):
            errors.append("source/destination: 預期交接前後兩邊的內容摘要")
        else:
            for key in ("imageIDs", "fileCardIDs"):
                old_ids, new_ids = source.get(key), destination.get(key)
                check(f"source.{key}", isinstance(old_ids, list) and len(old_ids) > 0, "來源須有此附件類型")
                check(f"destination.{key}", isinstance(new_ids, list) and len(new_ids) > 0, "目的端須保留此附件類型")
    elif case_id == "C436":
        check("testCompleted", observed.get("testCompleted") is True, "並行壓力測試須完整結束")
        check("crashed", observed.get("crashed") is False, "不得閃退")
        workers = observed.get("redactWorkerCount")
        check("redactWorkerCount", type(workers) is int and workers >= 2, "redact 須由多個工作執行緒執行")
        check("redactWorkersCompleted", type(workers) is int and observed.get("redactWorkersCompleted") == workers, "每個 redact 工作執行緒都須完成")
        redact_calls = observed.get("redactCallsCompleted")
        check("redactCallsCompleted", type(redact_calls) is int and type(workers) is int and redact_calls >= workers, "每個 redact 工作執行緒至少須完成一次呼叫")
        check("redactOverlappedMutations", observed.get("redactOverlappedMutations") is True, "redact 必須與主執行緒狀態操作實際重疊")
        check("mutationsRanOnMainThread", observed.get("mutationsRanOnMainThread") is True, "狀態操作必須在主執行緒執行")
        check("mainThreadMutationIterations", observed.get("mainThreadMutationIterations") == 1000, "主執行緒須完成 1,000 輪")
        for key in ("allowCalls", "reloadLearningCalls", "removeLearnedFeatureCalls"):
            check(key, observed.get(key) == 1000, "每輪各須執行一次，共 1,000 次")
        sanitizer = observed.get("threadSanitizer")
        if sanitizer is not None:
            if not isinstance(sanitizer, dict):
                errors.append("threadSanitizer: 若提供，預期 object")
            else:
                check("threadSanitizer.dataRaceReports", sanitizer.get("dataRaceReports") == 0, "TSan 不得回報 data race")
    elif case_id == "C438":
        check("isolatedStateDir", observed.get("allFixturesInsideStateDir") is True,
              "越界清理 fixture 必須全在隔離 state-dir 內")
        check("primaryWriteSucceeded", observed.get("primaryWriteSucceeded") is True,
              "primary 大草稿 writer 必須成功完成")
        check("primaryTraversalMarkerExists", observed.get("primaryTraversalMarkerExists") is True,
              "primary JSON 的路徑穿越不得刪除 drafts 目錄外標記檔")
        check("primaryOwnedOldImageRemoved", observed.get("primaryOwnedOldImageRemoved") is True,
              "合法且不再引用的 primary 舊圖應清除")
        check("recoveryWriteSucceeded", observed.get("recoveryWriteSucceeded") is True,
              "recovery writer 必須成功完成")
        check("recoveryTraversalMarkerExists", observed.get("recoveryTraversalMarkerExists") is True,
              "recovery JSON 的路徑穿越不得刪除 recovery 目錄外標記檔")
        check("recoveryOwnedOldImageRemoved", observed.get("recoveryOwnedOldImageRemoved") is True,
              "合法且不再引用的 recovery 舊圖應清除")
    else:
        return [f"不支援的案例：{case_id}"]
    return errors


def main():
    if len(sys.argv) not in (3, 4):
        print("用法：e74b99-exam-probe.py <案例 ID> <observation.json> [recovery-inspect.json]", file=sys.stderr)
        return 2
    case_id, observation_path = sys.argv[1:3]
    try:
        data = json.loads(Path(observation_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"失敗：無法讀取掛鉤輸出：{error}")
        return 1
    if not isinstance(data, dict) or data.get("caseId") != case_id:
        print(f"失敗：caseId 須為 {case_id}")
        return 1
    recovery_observed = None
    if case_id in {"C432", "C433"}:
        if len(sys.argv) != 4:
            print("失敗：C432／C433 必須分開提供復原前 prepare 與下次啟動 inspect 輸出")
            return 1
        try:
            recovery_data = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            print(f"失敗：無法讀取下次啟動 inspect 輸出：{error}")
            return 1
        if not isinstance(recovery_data, dict) or recovery_data.get("caseId") != case_id:
            print(f"失敗：inspect caseId 須為 {case_id}")
            return 1
        recovery_observed = recovery_data.get("observed")
    elif len(sys.argv) != 3:
        print("失敗：此案例只接受單一 observation JSON")
        return 2
    errors = errors_for(case_id, data.get("observed"), recovery_observed)
    for error in errors:
        print("失敗：" + error)
    if errors:
        return 1
    print(f"通過：{case_id} 草稿／交接契約")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
