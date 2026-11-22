# 考卷腳本

`scripts/exam.sh` 透過 [`prefs-sweep`](prefs-sweep) 包裝整輪考卷；`release.sh` 的離線驗證與正式出版必跑考卷都使用這個入口。`prefs-sweep` 只清理本輪之後新增、且完整檔名符合測試 suite 或 lid probe 規則的 plist，結束時列出開始／結束數量。自我測試請將 `EXAM_PREFS_DIR` 設到假 Preferences 目錄。

同步測試指令使用 command 模式：

```sh
scripts/exam/prefs-sweep -- <指令…>
```

`open -n` 會立即返回。手動啟動測試 App 時，必須以 `begin`／`end` 包住整個 session，不能只包住 `open`：

```sh
PREF_SWEEP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codenv-prefs-sweep.XXXXXX")"
STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codenv-state.XXXXXX")"
scripts/exam/prefs-sweep begin "$PREF_SWEEP_DIR"
open -g -n "$EXAM_APP" --args --state-dir "$STATE_DIR" --background --test-screen ipad --test-hidden --usage-fake --agy-bin "${CODENV_TEST_AGY_BIN:?請指定假 agy}"
# 執行紅燈／綠燈 probe；確認測試實例已完全退出後按 Enter。
printf '測試實例已退出、probe 已完成後按 Enter 繼續： '
read -r _
scripts/exam/prefs-sweep end "$PREF_SWEEP_DIR"
```

**手動開測試實例一律用 `prefs-sweep` 包起來。**紅燈、綠燈與單題 probe 都適用；每段測試結束後都要跑 `end` 並回報其數量摘要及錯誤。

可直接複製進施工-sonnet 任務單：

> 手動開啟 codenv 測試版的所有測試都必須用 `scripts/exam/prefs-sweep` 包起來，包含紅燈、綠燈與 probe。同步測試命令請用 `scripts/exam/prefs-sweep -- <指令…>`；若使用 `open -n`（它會立即返回），請在開 App 前執行 `prefs-sweep begin <暫存 session 目錄>`，以隔離 `--state-dir`、`--test-screen ipad`、`--usage-fake` 及假 `--agy-bin` 啟動並完成 probe，完全退出測試實例後再執行 `prefs-sweep end <同一 session 目錄>`。無論測試成功或失敗都要結束 sweep，並回報開始／結束數量及任何清掃錯誤；不得裸開測試 App，也不得更換 HOME。
