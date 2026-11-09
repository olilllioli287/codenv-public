# 固定測試考卷：歷史 bug 案例盤點

### C79：停用 macOS 視窗狀態還原

啟動隔離測試實例並讀取 `--window-restoration-probe` 輸出。預期 `ApplePersistenceIgnoreState=true`、`NSQuitAlwaysKeepsWindows=false`、主視窗 `isRestorable=false`；AppDelegate 的 secure restore、state restore 與 state save delegate 均回傳 `false`。主視窗、關於面板、程式碼實驗室執行視窗、獨立視窗、事件紀錄、浮動終端機、匯入、整理及設定視窗均明確停用還原。執行方式：`bash scripts/exam/native.sh C75 <repo 根目錄>`。

盤點範圍：`git log --all` 全部 **480 筆 commit**，涵蓋 2026-10-22～2026-11-05；搭配修正 diff、目前程式碼與測試入口檢查。純版本、規格、功能新增及沒有額外修正的合併不重複算 bug。

上一輪盤點時未修改檔案、未啟動 App 或瀏覽器、未執行網路操作。當時執行的離線測試結果（本輪結果另列於下方）：

| 指令 | 結果 |
|---|---|
| `node scripts/test-math.mjs` | 35 項通過 |
| `node scripts/test-plot.mjs` | 86 項通過 |
| `node scripts/quote-test.js` | 通過；包含 parser 與最小 DOM，沒有真實排版／WebKit |

## 判讀方式

- **A**：純 JS／Python 邏輯，可用 Node／Python 單元測試。
- **B**：需要 headless 瀏覽器及 `Resources/chat/test.html`。
- **C**：需要原生測試版 App、暫存 `--state-dir` 與測試掛鉤。
- **D**：完整驗收需要真人／實體操作；內部合成事件只能驗部分。
- **有**：找到針對該行為的自動斷言。
- **部分**：只有部分路徑被測，不能宣稱整個 bug 已涵蓋。
- **掛鉤**：已有操作、截圖或 dump 入口，**尚不等於自動回歸測試**。
- **未見**：在檢查範圍內未找到對應斷言。

以下簡寫：`W/`＝`Sources/Workbench/`、`J/`＝`Resources/chat/`、`S/`＝`scripts/`。總表的行號採**該修正 commit 的版本**，方便用 `git show <commit>:<path>` 核對；函式名稱則可用於追目前位置。

同一 commit 同時修數個問題時，列出子症狀及混合分類。草稿編號 `Axx`、`Bxx` 對應文末測試寫法。

## 所有辨識出的修 bug commit

### 2026-11-05～2026-11-01

| Commit | 日期 | 一句話症狀 | 根因位置／修正點 | 現有覆蓋；最便宜重跑 |
|---|---|---|---|---|
| `9457591` | 11-05 | 函數圖預設兩軸比例不同，格子不是正方形 | `J/plot.js:152`，`svg()` 比例與刻度間距 | **有** `test-plot.mjs`；**A，A01** |
| `a657704` | 11-05 | 圓被壓成橢圓，定義域端點使上下半圓接不起來 | `J/plot.js:149,206`，等比例尺寸與端點細分 | **有** `test-plot.mjs`；**A，A01、A02** |
| `8cd5f38` | 11-05 | 數學式串流時仍顯示原文；測試頁缺 `quote.js` 會空白 | `J/chat.js` `renderPartial()`；`J/test.html:35` | **部分**：math 單元測試不走串流 renderer；測試頁有 `?math=1`，缺斷言；**B，B01** |
| `08df98d` | 11-05 | 程式碼區方向導航直接跳隔壁格，沒有先走聊天／編輯器／結果 | `W/CodeLab.swift:526`、`MainWindow.swift:523`、`PrefixKeys.swift:139` | **掛鉤** `--focus-move`；**C** |
| `d0b1f06` | 11-02 | 編輯器的 Tab、`/`、⌃C、⌃Enter 被聊天室攔截 | `W/MainWindow.swift:484` 起的焦點判斷；`CodeLab.swift:1383` | **掛鉤** `--codelab …:edkey=…`；目前只直接演練 Tab／`/` 等部分；**C** |
| `9ccee64` | 11-01 | 上下分／不用 AI 模式跑完後，任意鍵返回程式碼與結果保留行為不完整 | `W/CodeLab.swift`、`CodeRunner.swift` 的結果畫面與按鍵監聽 | **掛鉤** `--codelab` 的 `key/state/ui`；**C** |

### 2026-10-31：目前 main 已包含的修正

| Commit | 日期 | 一句話症狀 | 根因位置／修正點 | 現有覆蓋；最便宜重跑 |
|---|---|---|---|---|
| `e93a637` | 10-31 | 重載歷史後，程式碼區附加行漏進使用者泡泡 | `J/chat.js:1648`，歷史文字剝除標記 | **有／部分**：`quote-test.js` 驗 parser 與歷史接線；**A，A03** |
| `656cea2` | 10-31 | 英文介面缺 30 條翻譯 | `Resources/i18n/en.json` | **未見**逐條回歸；`i18n-verify.py` 不驗翻譯完整性；**C** 設定／畫面快照 |
| `6417b29` | 10-31 | 暫時找不到對話仍消耗排程；刪掛件未通知排程 | `W/MainWindow.swift:807`；`Bundles.swift:257,281` | **掛鉤** `--schedule-dump`、`--store-op`；**C** |
| `b39dd3e` | 10-31 | 交接備份沒有跟測試／使用者 state 分開 | `W/MainWindow.swift:641`，交接備份目的地 | **掛鉤** `--handoff`；**C** |
| `16da93d` | 10-31 | `@discardableResult` 放錯位置造成編譯問題 | `W/ChatPane.swift:689` | **編譯檢查**；此項不是 A～D 的執行期案例，原生編譯即可，不必開 App |
| `bf0a253` | 10-31 | 交接或送出失敗會丟內容，程序退出留假泡泡，背景存檔可能跳衝突視窗 | `W/MainWindow.swift:638`、`ChatPane.swift:204,693`、`ChatSession.swift:28`、`CodeLab.swift:148,1022`、`MoveFolder.swift:76`、`Schedule.swift:154` | **部分**：引用測試只驗前端撤泡泡；其餘有 `--handoff/--chat-send/--schedule-dump/--codelab`；**C** |
| `0af8793` | 10-31 | state 未讀到就清排程，被擋排程無限重試，啟動缺備份 | `W/MainWindow.swift:791`；`Schedule.swift:119,178,279`；`Store.swift:139` | **掛鉤** `--fake-now`、`--schedule-dump`；**C** |
| `5d13ff4` | 10-31 | dirty 旗標誤判衝突；非 UTF-8 檔可能被覆蓋；Big5 新版無法載入 | `W/CodeLab.swift:934,970,999`，磁碟內容比對 | **掛鉤** `--codelab`；**C** |
| `6e02649` | 10-31 | ⌘⇧W、⌘⇧數字誤觸關格／切頁 | `W/PrefixKeys.swift:109,124`，修飾鍵比對 | **掛鉤** `--keys`、`--dump-layout`；**C** |
| `0f4f4c8` | 10-31 | 具名 Window 清名後，僅靠版面歸屬的掛件被當孤兒刪除 | `W/Bundles.swift:174` 起的留下成員計算 | **掛鉤** `--window-rename`、`--bundle-dump`；**C** |
| `0d4e5f5` | 10-31 | 編輯器存檔覆蓋 AI 已改過的磁碟新版 | `W/CodeLab.swift:973,994`，存前同步與衝突處理 | **掛鉤** `--codelab`，衝突選擇需補可控制入口；**C** |

### 2026-10-31：phone 分支修正

以下由 `--all` 找到，**目前 main 沒有 `Resources/remote`、`W/Remote` 或 `remote-md-test.js`**；測試覆蓋以 `phone` 分支版本判定，不能算成 main 已有。

| Commit | 日期 | 一句話症狀 | 根因位置／修正點 | 現有覆蓋；最便宜重跑 |
|---|---|---|---|---|
| `75dd5de` | 10-31 | 手機歷史漏出桌面引用區塊 | `W/Remote/RemoteTranscript.swift` `userText()` | **有** `RemoteTranscriptTests` 引用與純引用空泡泡；**C** `--remote-selftest transcript` |
| `8c46c79` | 10-31 | 截斷權限仍可回答、SSE 未連上仍訂閱、圖片解碼可能耗盡資源 | `RemoteAPI.swift:307`、`RemoteHTTP.swift:52`、`RemoteAuth.swift:201`、`RemoteBackendImpl.swift:102`、`ChatSession.swift:516` | **部分**：既有 API／HTTP 測試不等於逐個新分支都測到；**C** |
| `24b4b77` | 10-31 | 未驗證請求可先收大內文，loopback 判定過寬，未登入連線缺額度 | `RemoteAPI.swift:105` preflight；`RemoteHTTP.swift:101,192` | **有**新增 preflight、loopback、上傳與額度斷言；**C** `--remote-selftest api/http` |
| `f16e5a2` | 10-31 | 手機歷史／即時訊息漏出程式碼區與聊天室名稱附加行 | `RemoteTranscript.swift:104` `userText()` | **有** `RemoteTranscriptTests`；**C** |
| `2113994` | 10-31 | 手機 Markdown 特殊圍欄可無限迴圈，auto 模式被錯擋，殘留 uploads 未清理 | `Resources/remote/md.js`；`RemoteText.swift`；`RemoteAPI.swift`；`RemoteService.swift:67` | **有／部分**：Markdown 固定例＋20,000 筆固定種子 fuzz；隱形字元有測試，其餘需補；**A，A04／C** |
| `d308a7e` | 10-31 | 重設按鈕沒有進新密碼表單，session validate 反覆詢問鑰匙圈 | `RemotePage.swift:18,80`；`RemoteAuth.swift:140,194` | **部分** auth 測試，未見 UI／鑰匙圈呼叫次數斷言；**C** |
| `057df81` | 10-31 | 手機權限內容不完整、可代答選擇題、關閉後資源與喚醒歸屬未收乾淨 | `ChatSession.swift:89`；`RemoteBackendImpl.swift:101,223`；`RemoteService.swift:87` | **部分** API 測試；後端生命週期／圖片背景路徑仍需補；**C** |
| `3e1f604` | 10-31 | 攻擊者可鎖死帳號，隱形字元繞過指令阻擋，寫失敗仍刪秘密 | `RemoteAuth.swift:105,199,302`；`ChatPane.swift:907`；`RemoteBackendImpl.swift:33` | **部分**：限速與儲存失敗有 auth 斷言、隱形字元後由 `RemoteTextTests` 補上；**C** |

### 2026-10-30

| Commit | 日期 | 一句話症狀 | 根因位置／修正點 | 現有覆蓋；最便宜重跑 |
|---|---|---|---|---|
| `450511f` | 10-30 | 忙碌時送出失敗，`lastSent == nil` 導致文字圖片消失；附件 redo 不成對 | `W/ChatPane.swift:723`；`ChatInputBar.swift:457,911,955` | **掛鉤** `--chat-send/--chat-image/--dump-input/--keys`；**C** |
| `af1d7f4` | 10-30 | schedules 壞檔保護期間仍執行，新增／編輯假裝能存 | `W/Schedule.swift:148,229,306` | **掛鉤** `--schedule-put/--schedule-dump`；**C** |
| `bff1e23` | 10-30 | Gemini 換皮把回答內註腳一併藏掉 | `W/GeminiSkin.swift:502`，選擇器範圍 | **掛鉤** 本機網頁 fixture＋`--browser-shot`；**C** |
| `f1451d4` | 10-30 | 程式碼區 ⇧Tab 改聊天室權限；回報錯挑終端機 codenv_1 | `W/MainWindow.swift:522`；`BrowserTools.swift:106` | **掛鉤** `--keys`；回報目標需補斷言；**C** |
| `7e8734d` | 10-30 | 截圖回報退回草稿時蓋掉選取文字 | `W/BrowserTools.swift:110`，插入位置 | **未見**專用斷言；**C** |
| `ccb2e39` | 10-30 | 一張圖抓不到，Gemini 整次匯出永久等待 | `W/GeminiExport.swift:446`，20 秒逾時 | **未見**逾時斷言；用假下載器重跑；**C** |
| `4bf787c` | 10-30 | 換資料夾 state 寫失敗卻沒有提示 | `W/MoveFolder.swift:149` | **掛鉤** `--move-folder`；**C** |
| `46218de` | 10-30 | 看板交回用到舊 attempt，步驟編號可進入不安全路徑 | `W/CollabBoard.swift:653,663` | **掛鉤** `--collab-act …manualreturn…`；**C** |
| `bb62c9d` | 10-30 | 管線寫失敗但程序仍活著，下次送出無法重開 | `W/ChatSession.swift:578`，寫入失敗清理 | **掛鉤** 假 CLI＋`--chat-send`；**C** |
| `8d5c2da` | 10-30 | 刪 `[Image #n]` 後 ⌘Z 只救文字，沒有附件 | `W/ChatInputBar.swift:789`，undo 附件快照 | **掛鉤** `--input-key/--chat-image/--keys`；**C** |
| `122e79d` | 10-30 | 代送失敗未回 false，撤泡泡時可能撤錯或留下重複泡泡 | `W/ChatPane.swift:722`、`MainWindow.swift:636`；`J/chat.js:2175` `unsend()` | **部分** `quote-test.js` 驗 UUID 撤泡泡；原生返回值未涵蓋；**A，A05／C** |
| `2ace425` | 10-30 | 零位元 state／schedules 被永久視為壞檔而不再存 | `W/Store.swift:139,179`；`Schedule.swift:110` | **掛鉤** 暫存 state＋排程 dump；**C** |
| `7499b8d` | 10-30 | schedules 在但讀不到時仍可能覆蓋唯一原檔 | `W/Schedule.swift:110`，原檔保護 | **掛鉤** `--schedule-put/--schedule-dump`；**C** |
| `cf3e4d4` | 10-30 | 整理視窗把非 Claude 有紀錄的對話當空的 | `W/Organizer.swift:26`，跨後端大小統計 | **掛鉤** `--organizer-dump`；**C** |
| `747b73e` | 10-30 | 清草稿刪掉有 ! 紀錄、執行中或程式碼未存的對話 | `W/Drafts.swift:46` | **掛鉤** `--dump-panes/--bang-dump/--codelab`；**C** |
| `1641c75` | 10-30 | 新增排程分支被註解吃掉，新增存不進去 | `W/Schedule.swift:148` | **掛鉤** `--schedule-put/--schedule-dump`；**C** |
| `b95bdd1` | 10-30 | 非 Claude 紀錄寫失敗被吞掉，完全無法診斷 | `W/Transcripts.swift:90` 及各 Bridge 的 append | **未見**失敗日誌與一次性斷言；**C** |
| `078dc76` | 10-30 | Codex 完成事件的空思考摘要蓋掉已串流思考 | `W/CodexBridge.swift:337` | **未見**事件序列斷言；假 Codex；**C** |
| `97b80ce` | 10-30 | Gemini 把 `/路徑` 當指令吞掉，聊天室卡工作中 | `W/AgyBridge.swift:99`，只攔真正內部命令 | **掛鉤** 假 agy＋`--chat-send`；**C** |
| `aaaf7d4` | 10-30 | 網址／金鑰前緊接中文字時沒有去識別 | `W/EventLog.swift:244–266`，regex 邊界 | **未見**中文邊界斷言；**C** |
| `7aebb6e` | 10-30 | 本機壓縮程序忽略 SIGTERM 後永不結束 | `W/LocalCompact.swift:134`，延後 SIGKILL | **未見**專用斷言；假程序；**C** |
| `ee205fb` | 10-30 | 中斷本機回答後，下一輪變成連續兩個 user | `W/LocalBridge.swift:353,358`，補 assistant 收尾 | **未見**上下文序列斷言；**C** |
| `b39d1e3` | 10-30 | Codex 插話失敗晚到，回佇列後沒有再推進 | `W/CodexBridge.swift:185`，補 `next` | **未見**晚到回覆斷言；**C** |
| `48a7073` | 10-30 | 交接先封存舊對話，掛件及網址被當孤兒刪掉 | `W/MainWindow.swift:626`，先接手再封存 | **掛鉤** `--handoff/--bundle-dump`；**C** |
| `a86ba45` | 10-30 | 本機 Write／Edit 缺欄位時以空字串清檔／刪內容 | `W/LocalBridge.swift:687,695` | **未見**缺欄位不動檔斷言；**C** |
| `55b5ad3` | 10-30 | JS 錯誤把使用者程式片段寫到系統日誌；代送失敗未傳回 | `W/ChatPane.swift:723,910` | **未見**敏感字串不落日誌斷言；**C** |
| `755a005` | 10-30 | 對話清單空時，以差集刪掉全部排程 | `W/MainWindow.swift:785` | **掛鉤** state fixture＋`--schedule-dump`；**C** |
| `66b24e3` | 10-30 | ! 跑到一半關格子，已收輸出沒有保存 | `W/ChatPane.swift:311` | **掛鉤** `--bang-dump/--close-pane`；**C** |
| `1c70ea8` | 10-30 | 編輯排程復活已處理待送；截斷歷史後每日上限失準 | `W/Schedule.swift:148,212` | **掛鉤** `--fake-now/--schedule-put/--schedule-dump`；**C** |
| `8a394ce` | 10-30 | 原 Session 已關時還原 Window 失敗，關閉紀錄也消失 | `W/Layout.swift:604`，失敗放回 closed | **掛鉤** `--store-op …reopenwin…`；**C** |
| `eafad95` | 10-30 | 送失敗丟文字圖；游標在附件標記中間插入會切斷標記 | `W/ChatPane.swift:717`；`ChatInputBar.swift:986,999,1031` | **掛鉤** `--input-key/--chat-send/--dump-input`；**C** |
| `4eb5928` | 10-30 | F9／F10 等工具期間繼續打字，稍後舊快照蓋掉新字 | `W/CodeLab.swift:1032,1045,1096`，執行前重讀編輯器 | **掛鉤** `--codelab`＋延遲工具 fixture；**C** |
| `51add10` | 10-30 | 壓縮中關閉重複扣名額；本機 Bash 忽略 SIGTERM 不結束 | `W/LocalBridge.swift:371,721` | **未見**名額／強殺斷言；**C** |
| `48d4d7f` | 10-30 | 排程被擋卻記成已送，還污染輸入框 | `W/ChatPane.swift:875`；`MainWindow.swift:805` | **掛鉤** `--schedule-dump/--dump-input`；**C** |
| `32a5a3b` | 10-30 | 啟動重連使用舊對話副本，漏掉啟動後更新 | `W/Reconnect.swift:16`，重試時重新查對話 | **掛鉤** 假 CLI、`--rename/--conv-session`；**C** |
| `be25f65` | 10-30 | 圖片編輯器晚回存檔，覆蓋新草稿另一張圖 | `W/ChatInputBar.swift:1128`，原圖身分確認 | **未見**晚回存檔斷言；**C** |
| `68e4fa3` | 10-30 | Report／report 在不分大小寫磁碟互相覆蓋 | `W/Transcripts.swift:96,129`，碰撞比對正規化 | **未見**大小寫碰撞斷言；**C** |
| `2fa3411` | 10-30 | 刪專案後留下沒有成員的掛件框 | `W/Store.swift:229`，補 prune | **掛鉤** `--bundle-dump`；**C** |
| `30ea748` | 10-30 | 啟動失敗時讀仍在跑程序的 terminationStatus，丟例外 | `W/ChatSession.swift:284` | **掛鉤** 假 CLI 啟動失敗；**C** |
| `ce7c9b9` | 10-30 | 主視窗側欄拖到獨立視窗，改到主視窗版面 | `W/WindowHost.swift:1333` 起，drop 的 Window 範圍 | **部分掛鉤** 內部拖放可測模型；完整跨視窗拖放需補；**C** |
| `f97c06a` | 10-30 | 送失敗丟 ! 結果／交接；超長 JSONL 行截斷；同步讀重複顯示 | `W/ChatPane.swift:705,1130,1360`；`ChatSession.swift:359` 起 | **掛鉤** 假 CLI、`--chat-text/--chat-log`；**C** |
| `967df21` | 10-30 | 切終端機模式重建太早丟修改；! 執行中格子被收掉 | `W/MainWindow.swift:641`；`Workspace.swift:121` 起 | **掛鉤** `--keys/--codelab/--bang-dump`；**C** |
| `1bab03c` | 10-30 | 所有用量查詢失敗，舊資料仍被標「剛更新」 | `W/Usage.swift:148` 起 | **掛鉤** 假用量與讀取失敗參數；**C** |
| `3de5a22` | 10-30 | state 存在但讀不到仍覆蓋；確認同名不算已命名 | `W/Store.swift:176,289` | **掛鉤** 暫存 state、`--rename`；**C** |
| `b685a2c` | 10-30 | `/` 留在別格輸入框，沒有回紫框那格 | `W/MainWindow.swift:479`，焦點範圍判斷 | **掛鉤** `--keys/--dump-focus`；**C** |
| `3375127` | 10-30 | 「正在跑」第二行未對齊，窄欄模型名擠壓內容 | `W/Activity.swift` 執行項目列排版 | **掛鉤** `--render-usage`＋`CODENV_FAKE_RUNNING`；**C** |
| `4ed6cf1` | 10-30 | 從 Dock／⌘Tab／別 App 回來，被誤記成自行搶前景 | `W/FocusWatch.swift:28,35`，全域近期使用者操作 | **未見**完整自動測試；**D**，內部合成事件只能測部分 |
| `2979353` | 10-30 | Gemini 使用者泡泡過窄、上方留白，免責文字漏藏 | `W/GeminiSkin.swift:166` 起，寬度與選擇器 | **掛鉤** 本機 fixture＋`--browser-shot`；**C** |
| `fd73606` | 10-30 | 執行狀態列擠掉 shell 名稱，只剩 `she…` | `W/Activity.swift` 狀態列字級／壓縮優先序 | **掛鉤** `--render-usage`；**C** |
| `2b9e4fe` | 10-30 | 空 Window 找回關閉對話後，多留一個空分頁 | `W/Layout.swift:581`，還原取代空 Window | **掛鉤** `--sidebar-open/--dump-layout`；**C** |
| `4bcc15c` | 10-30 | Gemini 星星／問候及雙層泡泡殘留，NotebookLM 字色／網址錯 | `W/GeminiSkin.swift:116` 起；`NotebookSkin.swift:66`；`BrowserPane.swift:174` | **掛鉤** 本機 fixture、`--browser-shot/--store-op`；**C** |
| `bcde2c4` | 10-30 | 無 description 的背景指令認不出模型圖示 | `W/Activity.swift:41,248`，命令開頭配對 | **掛鉤** 假執行項目、`--render-usage`；**C** |
| `4920bc1` | 10-30 | Gemini 換皮選單透明、送出鈕失去高亮、亮底文字及泡泡框錯 | `W/GeminiSkin.swift` 色彩與各元件 CSS | **掛鉤** 本機 fixture＋明暗快照；**C** |
| `9d07e53` | 10-30 | Gemini 頂端留白底，整頁主題不一致 | `W/GeminiSkin.swift:40` 起，html 畫布／設計變數 | **掛鉤** 本機 fixture＋快照；**C** |
| `4e7786b` | 10-30 | F4 動畫取消、提早返回或換螢幕後，Timer／版面狀態殘留 | `W/WindowHost.swift:1036,1137,1221` | **部分掛鉤** `--resize/--snapshot`；換實體螢幕完整驗收 **D**，其餘 **C** |
| `70934f8` | 10-30 | 非 RGB 色直接取 RGB 分量，換皮丟例外 | `W/GeminiSkin.swift:18`；`NotebookSkin.swift:18` | **未見**非 sRGB 輸入斷言；**C** |
| `a810893` | 10-30 | 任意主機測試旗標影響 NotebookLM，關換皮有殘留，新舊網域漏認 | `W/GeminiExport.swift:18`；`GeminiSkin.swift:126`；`NotebookSkin.swift:13,87` | **掛鉤** 本機 fixture、`--browser-test/--browser-shot`；**C** |
| `6ee34df` | 10-30 | 解除「在別處進行」鎖定，搶走別格打字焦點 | `W/ChatPane.swift:1170`，只恢復原本就在本格的焦點 | **掛鉤** `--dump-focus`＋狀態切換 fixture；**C** |
| `1673b97` | 10-30 | 強制結束 App 後，排在未來的 SIGKILL 不會執行，留下 ! 孤兒程序 | `W/Bang.swift:245`，結束前同步等待／強殺 | **掛鉤** `--quit`＋假程序群組；**C** |

### 2026-10-29

| Commit | 日期 | 一句話症狀 | 根因位置／修正點 | 現有覆蓋；最便宜重跑 |
|---|---|---|---|---|
| `7b0496e` | 10-29 | 回報 zip 寫檔阻塞／失敗處理不足，ditto 啟動失敗崩潰，退稿提示失真 | `W/Feedback.swift:208` 起；`BrowserTools.swift:104`；`ChatPane.swift:672` | **掛鉤** `--feedback-dump`，失敗注入需補；**C** |
| `9d6d53c` | 10-29 | 閒置終端機誤算忙碌，背景工作漏算，Esc 無法正常取消結束 | `W/TerminalPane.swift:181`、`Workspace.swift:243`、`Activity.swift:108`、`main.swift` 結束流程 | **掛鉤** `--quit/--key-keys`；**C** |
| `9701d19` | 10-29 | 事件紀錄合併後漏 6 條英文 | `Resources/i18n/en.json` | **未見**特定字串回歸；**C** |
| `51014d9` | 10-29 | 執行程式加入無關工具路徑，PATH 重複設定 | `W/CodeRunner.swift:68,79,140` | **掛鉤** `--codelab …run…`＋假工具列印 PATH；**C** |
| `67abb39` | 10-29 | Codex 重置讀回失敗後永久停用，逾時不返回；JSON 秘密未遮罩 | `W/Usage.swift:45` 起與 reset 流程；`EventLog.swift:261` | **掛鉤** `CODENV_CODEX_RESET_*`、假讀失敗／延遲；未見完整斷言；**C** |
| `0f580b0` | 10-29 | 測試版開 Console 搶使用者焦點 | `W/EventLog.swift:476`，測試模式不用 activate | **未見**自動斷言；**C**，真前景影響可加人工驗收 |
| `2529c28` | 10-29 | 重置後過早解鎖、重試 key 不一致、初始化未等回覆，測試可能碰真 consume | `W/Usage.swift` reset／JSON-RPC／測試旁路 | **掛鉤** 假 Codex、重置結果檔；**C** |
| `93a3c2f` | 10-29 | 工具偵測期間換檔仍跑舊動作，紅線畫錯檔，偵測工具不在 PATH | `W/CodeLab.swift:418` 起；`CodeRunner.swift:68,123`；`CodeLabSetup.swift:31` | **掛鉤** `--codelab`＋延遲工具；**C** |
| `284a96a` | 10-29 | JS 錯誤與帳號資訊洩漏到事件紀錄；Console 行數及 flush 無上限 | `W/ChatPane.swift:867`；`EventLog.swift:47` 起 | **未見**遮罩／行數／逾時斷言；**C** |
| `191b585` | 10-29 | 事件紀錄洩漏使用者自訂螢幕名稱 | `W/EventLog.swift:266` 起，螢幕摘要 | **未見**名稱不外露斷言；**C** |
| `4c7af58` | 10-29 | 事件紀錄含標題／路徑／錯誤細節，清除與保留天數不正確 | `W/EventLog.swift`；各呼叫點改 ID、檔名、domain/code | **未見**完整隱私及保留邊界斷言；**C** |
| `9d68c1f` | 10-29 | 舊執行 session 的晚到終了事件，把新一輪當成已結束 | `W/CodeRunner.swift:407,468` 起，停止收尾與 session 身分 | **掛鉤** `--codelab stop/run/ui`；**C** |
| `fca240f` | 10-29 | SEGV 錯誤紅線沒有來源行號 | `W/CodeRunner.swift:65`，編譯補 `-g` | **掛鉤** `--codelab run`＋Monaco markers；**C** |
| `049027b` | 10-29 | 具名 Window 關閉後側欄框消失，掛件被清掉 | `W/Bundles.swift:141,156`，納入 closed Windows | **掛鉤** `--store-op closewin/reopenwin`、`--bundle-dump`；**C** |
| `d6989fd` | 10-29 | 換檔中關閉未等存完，停止鈕卡住，SEGV 誤分類 | `W/CodeLab.swift:113` 起；`CodeRunner.swift:241,359` 起 | **掛鉤** `--codelab`；**C** |
| `d8538a3` | 10-29 | 「正在跑」名字多行撐破列高、✕ 錯位，時間被模型標籤擠掉 | `W/Activity.swift:90,404` 起 | **掛鉤** `--render-usage`＋`CODENV_FAKE_RUNNING`；**C** |
| `442c9d4` | 10-29 | 執行／檢查沒有接開發工具 readiness，缺工具時失敗 | `W/CodeLab.swift:992,1039`；`CodeLabSetup.swift` | **掛鉤** `--codelab` 與測試偵測設定；**C** |
| `9bd09f9` | 10-29 | 程式碼區存錯檔、空資料夾卡住、輸出灌爆、檢查誤報 | `W/CodeLab.swift` 檔案／dirty／執行流程；`CodeRunner.swift` 輸出上限及檢查 | **掛鉤** `--codelab open/settext/check/run/stop/menu/ui`；**C** |
| `4f7b4fb` | 10-29 | 額度連續計數歸零，停止同時跳格，獨立瀏覽器 F5 失效，視窗位置還原錯 | `S/codenv-todo:1071`；`W/Activity.swift:395`；`DetachedWindow.swift:62`；`PrefixKeys.swift:32`；`Layout.swift:123`；換皮與右欄排版 | **未見** Python 計數斷言；原生有操作／快照掛鉤；**A，A10／C** |
| `52279dd` | 10-29 | 舊程序輸出混新對話、IME Enter 被攔；看板誤判額度／睡醒誤殺／環境與路徑驗證不足 | `W/ChatSession.swift:259`、`ChatInputBar.swift:38`；`S/codenv-todo` `is_temp/any_alive/AgyRunner/edit` | **掛鉤** `--chat-respawn/--keys`；Python 未見固定測試；**A，A11～A14／C** |
| `b6fdaed` | 10-29 | 獨立視窗與版面狀態不同步，送出鈕誤匹配、NotebookLM 換行不能復原 | `W/Layout.swift:218` 起；`LayoutEdit.swift`；`DetachedWindow.swift:116`；`GeminiExport.swift:71,107` | **掛鉤** `--dump-layout/--dkeys/--browser-test`；**C** |
| `6ac6aba` | 10-29 | NotebookLM 圓鈕亮暗寫反；等待送出時忽略內容變更；選擇器依賴語言 | `W/BrowserPane.swift:197`；`GeminiExport.swift:68,91` 起 | **掛鉤** 本機 fixture＋`--browser-test`；**C** |
| `714b546` | 10-29 | 網頁第一則訊息送不出去，網站切換與最後網址不一致 | `W/GeminiExport.swift:68` 起；`BrowserPane.swift`；`Bundles.swift:82` | **掛鉤** `--browser-test/--store-op`；**C** |
| `e349c1a` | 10-29 | 目前 Window 只有空格子，點未顯示對話仍另開 Window | `W/Layout.swift` 的側欄開啟／空版面判定 | **掛鉤** `--sidebar-open/--dump-layout`；**C** |
| `5188f0a` | 10-29 | 拖曳中斷後留下半透明接收區／拖曳狀態 | `W/WindowHost.swift` drag cleanup；`main.swift` 測試入口 | **掛鉤** `--drag-reset`；**C** |
| `349aa5a` | 10-29 | Claude 的 task notification 被畫成一般使用者泡泡 | `J/chat.js:1932,1945`，user 事件分類 | **未見**專用斷言；**B，B11** |
| `593aaf7` | 10-29 | 審查批次：遲到存檔寫錯檔、symlink 越界、壞檔覆蓋、版面丟格／搶焦點，以及 CLI 解析錯誤 | 主要：`W/CodeLab.swift:633,778`、`Store.swift:141,163`、`MoveFolder.swift:49` 起、`WindowHost.swift:909,1033,1110`、`Transcripts.swift:94` 起；`S/codenv-todo` `parse_step/AgyRunner.finish/stop_orphan`；`S/codenv-browser:94` | **未見**批次完整回歸；原生有操作掛鉤；CLI 可純測；**A，A07～A09／C** |

`593aaf7` 尚包含應保留為後續子案例的修正：非 Claude 草稿判空、Groups／Layout 缺欄位解碼、隱藏終端機攔捲動、Bash 孤兒群組、模型壓縮關閉後續跑、Apple 取消未收尾、預設設定等待回覆不結束、JSONL 截短後未重讀、紀錄檔名 UTF-8 位元組上限與碰撞、改名寫失敗回復、粗體錯誤提亮背景、重複 image shelf／observer、封存與排序。根因分別在同 commit 的 `Drafts/Groups/Layout/TerminalPane/Bang/LocalBridge/AppleBridge/ChatSession/ChatPane/Transcripts/Theme/WindowHost/Archive.swift`；均未見對應的完整固定斷言，最低為 **C**。

### 2026-10-28～2026-10-26

| Commit | 日期 | 一句話症狀 | 根因位置／修正點 | 現有覆蓋；最便宜重跑 |
|---|---|---|---|---|
| `8e858de` | 10-28 | `&` 放到背景的 agy／codex／copilot 沒列入正在跑 | `W/Activity.swift`、`ProcessScan.swift`，子程序掃描 | **掛鉤** 假背景程序＋`--render-activity`；**C** |
| `6a73861` | 10-27 | Gemini 匯出只拿低解析預覽圖 | `W/GeminiExport.swift:437` 起，原尺寸變體／像素選擇 | **部分** `--gemini-selftest` 偏 cookie／轉址，未涵蓋實際像素選擇；**C** |
| `47fe12c` | 10-27 | 圖片跨 Google 網域轉址時沒 cookie，下載失敗或混入非圖片 | `W/GeminiExport.swift:370` 起，ephemeral session／cookie 篩選 | **有／部分** `--gemini-selftest`；實際下載路徑需假下載器；**C** |
| `5e65d52` | 10-27 | body 的 class 讓所有匯出圖片被祖先過濾器誤擋 | `W/GeminiExport.swift:151`，祖先檢查止於當輪 | **未見** DOM fixture 斷言；**C** |
| `aa5eca6` | 10-27 | Gemini 未渲染輪次匯出空白，使用者文字／預覽圖被漏抓 | `W/GeminiExport.swift:136,262` 起；`BrowserPane.swift:202` | **掛鉤** 本機 fixture＋匯出；**C** |
| `bfbe834` | 10-27 | 含頓號的選項被拆成「其他」；指令選單點擊／捲動選取錯誤 | `J/chat.js` `splitChosen()`；`W/SlashMenu.swift:110,123` | **未見**專用斷言；**A，A06／C** |
| `e908375` | 10-27 | 看板壞檔誤覆蓋／報 traceback，額度誤判不退還，CLI 逾時與按鍵卡住 | `S/codenv-todo` `load/edit/AgyRunner.finish`；`S/codenv-browser` `ask()`；`W/AgyNet/Usage/PrefixKeys/CodeLab.swift` | **未見**Python 固定測試；原生掛鉤部分；**A，A11、A15／C** |
| `ec382d2` | 10-27 | ! 壞檔被覆蓋、輸入暫存丟失、掛件被清、搬移太早、失敗提問污染 Apple 前文 | `W/Bang.swift:41`、`ChatInputBar.swift:820` 起、`Bundles.swift:197`、`MoveFolder.swift:104`、`AppleBridge.swift:110`、`Workspace.swift:121` | **掛鉤** `--bang-dump/--dump-input/--move-folder/--dump-layout`；**C** |
| `f739411` | 10-27 | 遠端圖片自動外連、本機模型誤接外部服務、猜下一句串錯輪、空對話篩選過時 | `W/LocalImages.swift:16` 起；`LocalBridge.swift:42`；`NextGuess.swift:12`；`Organizer.swift:29`；`Sidebar.swift:751` | **掛鉤** `--organizer-dump` 等；未見完整斷言；**C** |
| `2be92cb` | 10-27 | 第一批：寫失敗仍成功、換檔丟修改、草稿誤刪、排程重送、管線卡住、遠端圖片自動載入 | `W/CollabBoard.swift:448`、`CodeLab.swift:690`、`Drafts.swift:42`、`Schedule.swift:105`、`ChatSession.swift:485`；`J/chat.js:946`；`S/codenv-browser:89` | **未見**批次回歸；原生掛鉤；圖片可 B、CLI 可 A；**A，A15、A16／B，B08／C** |
| `d092070` | 10-26 | 啟動重連時舊 Claude 尚未退出，直接放棄接回 | `W/Reconnect.swift` 重試流程 | **掛鉤** 假 Claude＋`--dump-panes`；**C** |
| `a064a91` | 10-26 | 程式碼區窄版工具列放不下 | `W/CodeLab.swift` bar layout／壓縮級別 | **掛鉤** `--codelab …snap=…`；**C** |
| `112ab3c` | 10-26 | Bang 收尾阻塞主執行緒；無法解碼程式檔仍開啟而可能覆蓋 | `W/Bang.swift:100` 起；`CodeLab.swift:74,165`；`CodeRunner.swift:174` | **掛鉤** `--bang-stop/--codelab`；**C** |
| `e6a3337` | 10-26 | ! 測試旗標未限定測試 state，可作用正常資料 | `W/main.swift:211`，測試入口 guard | **未見**guard 斷言；**C** |
| `a0177b0` | 10-26 | i18n 盤點把 JS 註解裡的 `L()` 算成待翻譯 | `S/i18n-report.py:88`，`js_keys()` | **未見**fixture 測試；**A，A17** |
| `5fe30e7` | 10-26 | 公版二進位含私人建置路徑；DMG 輸出變數與中文相連解析錯 | `public/release-public.sh:16,36` | **部分**腳本已有成品洩漏阻擋，但不是獨立回歸；變數可 **A，A18** 靜態檢查；建置路徑需另做離線打包檢查 |

`2be92cb` 的其他子案例位置：刪對話前未確保垃圾桶成功在 `Store.swift:155`；目錄／分類寫失敗在 `DirPicker.swift:28`、`Groups.swift:228`；控制字元路徑跳脫在 `DropPaste.swift:70`；交接與壓縮輸出上限在 `Handoff.swift:52`、`LocalCompact.swift:132`；Codex steer 失敗回佇列在 `CodexBridge.swift:180`；Apple 中斷上下文在 `AppleBridge.swift`；舊用量提示在 `Usage.swift:518`。這些最低為 **C**，未見逐項固定斷言。

### 2026-10-25～2026-10-23

| Commit | 日期 | 一句話症狀 | 根因位置／修正點 | 現有覆蓋；最便宜重跑 |
|---|---|---|---|---|
| `ff68cb2` | 10-25 | 網頁縮放後內容超出瀏覽器格子 | `W/BrowserPane.swift:173`，改 `pageZoom` | **掛鉤** `--browser-test/--browser-shot`；**C** |
| `a08aab8` | 10-25 | 中文／裸路徑不能點、單一 `~` 被當刪除線、檔名沒確認存在 | `J/chat.js:206` 起，路徑辨識及 Markdown；`W/ChatPane.swift:729,965` | **未見**專用斷言；JS 接線 **B，B02**，Finder／存在性後端 **C** |
| `d188628` | 10-25 | 整理對話視窗把隱藏掛件算成對話／資料夾數量 | `W/Organizer.swift:34,56,175` | **掛鉤** `--organizer-dump`；**C** |
| `e0f20a1` | 10-25 | Markdown 本機圖片顯示破圖，中文／空格路徑錯誤 | `J/chat.js:209` 起；`W/LocalImages.swift` scheme handler；`ChatPane.swift:97` | **未見**完整圖片載入斷言；**C** `--web-snapshot` |
| `e16f3fc` | 10-25 | 貼上普通路徑文字被誤轉成附件卡片 | `W/ChatInputBar.swift:138` 起，pasteboard 類型分流 | **掛鉤** `--input-files/--dump-input`，純文字貼上需補入口；**C** |
| `228fbd0` | 10-25 | 斷網仍叫 agy，一直開登入頁；送失敗丟輸入 | `W/AgyNet.swift`；`ChatPane.swift:649`；`ChatInputBar.swift:552` | **掛鉤** `--agy-offline/--agy-net-test`；**C** |
| `bb5dcf2` | 10-25 | App 啟動的 Claude 找不到 `~/.local/bin` 裡的 CLI | `W/Workspace.swift:161`，PATH | **掛鉤** 假 Claude 列印環境；**C** |
| `c1f4518` | 10-25 | 一個卡住 socket 阻擋其他 codenv-browser 請求，回應永等 | `W/BrowserServer.swift:79,104`，逐連線處理與逾時 | **未見**併發／逾時斷言；**C** |
| `ee8e18f` | 10-25 | 本機壓縮 `post_tokens` 用字數冒充 token | `W/LocalCompact.swift:46`；`LocalBridge.swift:369` | **未見**估算值斷言；**C** |
| `2c266ea` | 10-25 | 輸入框把預設模型錯顯示為 Sonnet | `W/ChatPane.swift:327` 起 | **掛鉤** 假 init 事件＋`--dump`；**C** |
| `0e702a9` | 10-25 | 右側欄把實際預設模型錯顯示成 Sonnet | `W/Store.swift:61`；`ChatPane.swift:66`；`ContextSize.swift:112` | **掛鉤** 假 init／`--render-usage`；**C** |
| `f69b779` | 10-25 | 看圖模型的 thinking 開關未正確傳給伺服器 | `W/LocalBridge.swift:162,387` | **未見**啟動參數斷言；**C** |
| `7ca1618` | 10-25 | 關閉程式碼區未等存檔，存失敗仍收掉 | `W/CodeLab.swift:80,533`；`Workspace.swift:107` | **掛鉤** `--codelab/--close-pane`；**C** |
| `b0c8bd2` | 10-24 | 在組裡開新對話卻沿用其他對話資料夾 | `W/Groups.swift:41`，依組路徑解析 | **掛鉤** `--new-in-group/--dump-layout`；**C** |
| `d949774` | 10-24 | 換資料夾的測試把暫存紀錄丟進使用者垃圾桶 | `W/MoveFolder.swift:42`，測試模式直接刪暫存 | **掛鉤** `--move-folder`；**C** |
| `d57a960` | 10-24 | 開不同區的對話時側欄沒有切到對應區 | `W/Sidebar.swift`、`Layout.swift` 區域選取同步 | **掛鉤** `--area/--sidebar-open/--dump-layout`；**C** |
| `6445afe` | 10-24 | 從預設換模型後永遠顯示思考中 | `W/ChatSession.swift:520`，local-command 回報誤當新一輪 | **掛鉤** 假 Claude＋`--chat-model`；**C** |
| `54bc0a8` | 10-24 | release 訊息的全形括號被吃進變數名，輸出亂掉 | `release.sh:36,57`，`${DMG}`／`${DEST}` | **未見**回歸；**A，A18** 靜態檢查，不執行 release |
| `2da3b5e` | 10-24 | 精簡模型清單漏列 Sonnet／Haiku | `W/ModelPopover.swift` 精簡模式篩選 | **掛鉤** `--render-models/--shot-models`；**C** |
| `3646e94` | 10-24 | 換過模型後歷史看不到前一家對話 | `W/ChatPane.swift` 歷史檔集合與交接分隔 | **掛鉤** `--chat-text`＋跨後端歷史 fixture；**C** |
| `b042abe` | 10-24 | 輸入框 ⌘↑↓ 意外跳整個對話，而非移游標 | `W/ChatInputBar.swift:69` 起 | **掛鉤** `--keys/--dump-input/--dump-focus`；**C** |
| `ecff7cd` | 10-24 | 換模型後新模型讀不到前文 | `W/ChatPane.swift:545,644`；`J/chat.js:1507` | **掛鉤** 假後端、`--chat-model/--carry-dump`；**C** |
| `9aff461` | 10-24 | 聊天進行中，拖檔停在分頁上不會切 Window | `W/WindowHost.swift:386,392,407` | **掛鉤** `--spring/--spring-sample`；**C** |
| `5865652` | 10-24 | 分割權重清單過時，已下載模型仍不列出 | `W/LocalBridge.swift:177,179`，看實際權重檔 | **未見**模型資料夾 fixture 斷言；**C** |
| `6376465` | 10-24 | Gemini 取消當輪後，模型仍接著回答已取消內容 | `W/AgyBridge.swift:79,99,109`；`ChatSession.swift:370` | **掛鉤** 假 agy＋停止／下一輪；**C** |
| `566d9d5` | 10-24 | 回覆中排隊的訊息太早寫進 Gemini／Codex／Copilot 紀錄，順序錯 | 各 Bridge 的 waiting→開始執行／persist 接點 | **掛鉤** 假後端＋`--chat-send`；**C** |
| `ea096cc` | 10-24 | 本機讀檔計算溢位、Bash 留背景程序卡住，Apple／本機紀錄順序錯 | `W/LocalBridge.swift` 工具／程序收尾；`AppleBridge.swift:92` | **未見**完整回歸；**C** |
| `5788529` | 10-24 | 精簡模型清單漏本機模型 | `W/ModelPopover.swift` 模型篩選 | **掛鉤** `--render-models`；**C** |
| `066d226` | 10-24 | 未被讀取的排隊訊息在程序退出後假裝已送出 | `J/chat.js` `unconfirmed/onResult/flushQueued/markLost` | **未見**對應斷言；**B，B10** |
| `b18dc09` | 10-24 | 思考區塊顯示兩次 | `J/chat.js:1734`；各 Bridge 思考／完成事件處理 | **未見**完整事件回歸；前端 **B，B03**，Bridge **C** |
| `900f59d` | 10-24 | 空資料夾拖到「沒有對話」區無法接收 | `W/Sidebar.swift:279,303,328` | **掛鉤** `--drop`／TestDrag；**C** |
| `d1ab4e9` | 10-23 | 模型面板換頁會位置跳動 | `W/ModelPopover.swift:189` 起；`ChatPane.swift:348` | **掛鉤** `--anim-models`；**C** |
| `86cf268` | 10-23 | 焦點在聊天內容時，⌃Enter／⌃C 不作用 | `W/MainWindow.swift` 聊天區快捷鍵入口 | **掛鉤** `--keys/--dump-focus`；**C** |
| `a70357d` | 10-23 | 內容暫縮造成瀏覽器夾捲動位置，被誤判成使用者往上捲而停止貼底 | `J/chat.js` `initScroll/userUp/stick` | **未見**斷言；**B，B04** |
| `541430f` | 10-23 | 送訊息後不能持續跟住最新一行 | `J/chat.js` magnet／following／scroll handlers | **未見**斷言；**B，B05** |
| `4dc4e37` | 10-23 | 工具／思考增長時未穩定貼底，忙碌中缺保底追隨 | `J/chat.js` 捲動；`W/ChatPane.swift` scroll bridge | **未見**斷言；前端 **B，B06**；原生快捷鍵 **C** |
| `b86c88f` | 10-23 | 自動接回對話被誤鎖成「在別處進行」 | `W/ChatPane.swift:618,687`；`Reconnect.swift:31` | **掛鉤** 假 Claude／重連 fixture；**C** |
| `d43fec6` | 10-23 | 工具與思考串流長高後，框內／整頁沒有跟到最新內容 | `J/chat.js` ToolCard／thinking render 接點 | **未見**斷言；**B，B06** |
| `055c163` | 10-23 | Pane 外框被內容蓋住，目前格紫框不完整 | `W/WindowHost.swift:8` 起，框的疊放／繪製 | **掛鉤** `--snapshot`；**C** |
| `ace824b` | 10-23 | 工具／思考展開收合與長行溢出不正確 | `J/chat.js` 工具／思考互動；`J/chat.css` 換行 | **未見**斷言；**B，B07** |
| `814e25b` | 10-23 | Bash 非零 exit 一律畫失敗紅叉；空輸入框無法立即插話 | `J/chat.js:864,909`；`W/ChatInputBar.swift:232,500` | **未見**斷言；顯示 **B，B09**，快捷鍵 **C** |
| `2d965a4` | 10-23 | 停止執行只停外層，子程序／忽略 SIGTERM 的死迴圈留著 | `W/CodeRunner.swift:258` 起，程序群組與強殺 | **掛鉤** `--codelab stop`；**C** |

### 合併去重對照

以下合併把上表修正帶入主線，沒有另建立相同案例；`75dd5de` 有手機引用剝除的額外修正，已單列。

| 日期 | 合併 commit | 對應修正 |
|---|---|---|
| 10-31 | `16aeffe`、`7592d80`、`13196cf`、`f08753e` | audit／第 4 批／CodeLab 磁碟比對／掛件／快捷鍵 |
| 10-30 | `0d5ffc8`、`a64914e`、`7f2b384`、`11215de`、`2ee180a`、`fb34040` | Gemini／NotebookLM 換皮、空 Window、F4 動畫 |
| 10-29 | `5abdc6e`、`aaaa990`、`f61121d`、`1dd0926`、`eb5dcae`、`3cf3c89` | 瀏覽器工具、結束確認、CodeLab、事件紀錄 |

## 固定考卷：執行方式與本輪結果

```sh
scripts/exam.sh           # 預設 dev：開發組 10 題
scripts/exam.sh dev
scripts/exam.sh holdout   # 保留組：2 題 A，3 題 C 待做
scripts/exam.sh all       # 開發組＋保留組＋4 組既有測試
node scripts/exam/verify-old.mjs all  # 相同斷言對修正前檔案做反證
```

需求：Node（內建 `WebSocket`、`fetch`）、Python 3、git、本機 Microsoft Edge 與 macOS `sandbox-exec`，無額外套件。每題獨立程序，有逾時限制。任何已實作題目失敗皆 exit 1；C 類另印「待做」，不冒充通過。非法模式 exit 2。dev 只載入 `scripts/exam/dev/cases.json`，不讀取或執行 holdout 的考題；holdout fixture 與斷言放在 `scripts/exam/holdout/`。

B 類入口為 `Resources/chat/test.html?bare=1&fast=1&exam=B01`（另有 `B10`、`B04`）。以 `--remote-debugging-port=0` 讓 OS 直接配發空埠啟動獨立 headless Edge（從該次 profile 的 `DevToolsActivePort` 讀回，避免埠釋放後被搶占），再透過 CDP 等待 `window.__done` 與檢查 `window.__exam`；不使用 dump-dom、screenshot CLI 或 virtual-time-budget。B04 的對照使用 CDP `Input.dispatchMouseEvent` 真實滾輪。每題使用暫存 HOME、設定檔與 user-data-dir；OS sandbox 禁止外網及使用者的 `~/Library`、`~/.claude` 讀寫，CDP 再禁止非本機資源。清理邏輯涵蓋正常、失敗、逾時與 SIGINT／SIGTERM，針對自己開的 Edge 程序群組及暫存資料（本環境尚無法驗證 Edge 實際啟動後的清理），不關閉既有 Edge。

**本輪尚未全通過**：`scripts/exam.sh all` 實際結果為 **通過 13、失敗 3、待做 3，exit 1**。9 題 A 類與 4 組既有測試通過；B01／B10／B04 尚未啟動 Edge，被本次執行環境擋住：最終輸出為 `sandbox-exec: sandbox_apply: Operation not permitted`；先前 Node 探測本機空埠也回報 `listen EPERM 127.0.0.1`，這些是基礎設施錯誤，尚無測試斷言結果。必須在允許 macOS sandbox-exec 與本機 TCP 的終端重跑 `scripts/exam.sh all` 及舊版驗證指令，才能完成 B 類現版／舊版驗證。未嘗試提權、未使用替代瀏覽器或假 DOM 當作 B 類通過。

- 完整本輪輸出：[`docs/exam-output.txt`](exam-output.txt)。既有 math 35 項、plot **89 項**、quote parser／最小 DOM、resume 離線續跑測試皆通過。
- 舊版逐題輸出：[`docs/exam-old-output-all.txt`](exam-old-output-all.txt)；機器可讀結果：[`scripts/exam/old-results-all.json`](../scripts/exam/old-results-all.json)。9 題 A 類、10 個歷史版本反證均成功（A01 驗兩個版本）；3 題 B 類均「無法驗」。
- 舊版驗證只用 `git show <fix>^:<file>`，換入暫存副本的列明檔案；其餘資源與相同斷言維持本輪版本。先確認目前版通過，再要求舊版於指定的行為斷言失敗；缺 API 的 TypeError、依賴錯誤、環境阻擋與逾時均不當成歷史 bug 證據。
- `scripts/test-resume.sh` 原有流程會在**暫存 fixture repo** 建立測試 commit；push／gh 為替身，僅使用本機檔案。沒有對目前 worktree commit／push，也沒有啟動 codenv App。

### 本輪檔案清單

修改：`Resources/chat/test.html`、`docs/exam-cases.md`。

新增：

```text
scripts/exam.sh
scripts/exam/common.mjs
scripts/exam/run.mjs
scripts/exam/logic.mjs
scripts/exam/dom.cjs
scripts/exam/todo.py
scripts/exam/todo_support.py
scripts/exam/browser.mjs
scripts/exam/scenarios.js
scripts/exam/verify-old.mjs
scripts/exam/dev/cases.json
scripts/exam/holdout/cases.json
scripts/exam/holdout/todo.py
scripts/exam/old-results-all.json
docs/exam-output.txt
docs/exam-old-output-all.txt
```

原有四組測試與使用者提供的 `scripts/.cdp-example.mjs` 均未修改。

本輪固定範圍是下列 15 題；其餘 A／B 草稿尚未納入。C13～C15 依要求待做。清單下方草稿仍保留作為後續擴充規格。

## 已固定的 15 題

排序依據是**固定輸入的重現穩定度、重跑成本、可觀察的明確預期**。這是挑題優先序，並非估算真實使用者發生頻率。

### 開發組：10 題

| 優先 | 案例 | 來源 | 類別 | 固定輸入與驗收重點 | 舊版會失敗 |
|---|---|---|---|---|---|
| 1 | 選項文字含分隔符仍完整還原 | `bfbe834` | A／A06 | `紅、綠` 是一個選項，不拆成兩個「其他」 | **是**；`bfbe834^` 把「紅、綠」拆成紅／綠 |
| 2 | 看板步驟不誤拆 email／`@State` | `593aaf7` | A／A07 | 無尾端負責人時原文完整；顯式 owner 優先 | **是**；`593aaf7^` 把 email 拆為 owner `b.com` |
| 3 | HANDOFF 後有補充文字仍判對狀態 | `593aaf7` | A／A08 | 取最後有效 HANDOFF，保留其後補充 | **是**；`593aaf7^` 把 need-user 判成 done |
| 4 | 歷史重載剝掉內部附加行 | `e93a637` | A／A03 | 程式碼區／名稱／換模型不外露，正常提問保留 | **是**；`e93a637^` 歷史泡泡漏出程式碼區標記 |
| 5 | 撤送失敗泡泡只依指定 UUID | `122e79d` | A／A05 | 撤 `failed` 不撤其他泡泡，不清引用選取 | **是**；`122e79d^` 送失敗泡泡仍存在 |
| 6 | 半圓定義域端點接合 | `a657704` | A／A02 | 原範圍＋不對齊取樣點的 `x: -6.01..6.02`，兩端距離均 `<1.5px` | **是**；`a657704^` 不對齊取樣點時端點差 5.56px |
| 7 | 圓與格子等比例 | `a657704`、`9457591` | A／A01 | 圓寬高比接近 1；auto 刻度格寬高相等 | **是**；`a657704^` 與 `9457591^` 圓寬高比 2.686 |
| 8 | 串流尚未完成就排版數學式 | `8cd5f38` | B／B01 | 不靠 final assistant 事件補救 | **無法驗**；`8cd5f38^` 已取出，現版／舊版皆被 sandbox_apply EPERM 擋住 |
| 9 | 未被讀取的排隊訊息標沒送到 | `066d226` | B／B10 | 程序退出後 `.lost`，刪除只影響該則 | **無法驗**；`066d226^` 已取出，同上 |
| 10 | 內容縮短造成位移不解除貼底 | `a70357d` | B／B04 | 沒有使用者輸入時重長回仍貼底；真往上捲才解除 | **無法驗**；`a70357d^` 已取出，同上 |

### 保留組：5 題

保留組日常不加入開發回饋，只在規則精簡前後各驗一次。已以獨立 fixture／runner 保存，不把每次輸出混入日常調整紀錄。

| 優先 | 案例 | 來源 | 類別 | 固定輸入與驗收重點 | 舊版會失敗 |
|---|---|---|---|---|---|
| 11 | 回答提到 quota 不得誤判額度用完 | `52279dd` | A／A11 | stdout 含 `429/rate limit`、stderr／agy log 無額度錯誤；不暫停、不退回 | **是**；`52279dd^` 回答文字誤觸 quota 退回 todo |
| 12 | 呼叫者 TMPDIR 不得擴大允許工作區 | `52279dd` | A／A12 | 假 TMPDIR 指向非暫存目錄，`is_temp()` 仍拒絕 | **是**；`52279dd^` 假 TMPDIR 子目錄被允許 |
| 13 | 空檔可恢復、非空壞檔受保護 | `2ace425`、`3de5a22`、`7499b8d` | C | 空 state／schedules 可重建；非空損毀原始 bytes 不變 | 可驗；`native.sh C13`（EXAM_APP=） |
| 14 | 舊檔遲到的 save 不得寫新檔 | `593aaf7` | C | 開 B 後收到 `path=A` 的 save；B 的 bytes 不變 | 可驗；`native.sh C14`（EXAM_APP=） |
| 15 | 編輯器焦點不被聊天快捷鍵搶走 | `d0b1f06` | C | Tab、`/`、⌃C、⌃Enter 各自測；另有聊天焦點正向對照 | 可驗；`native.sh C15`（EXAM_APP=），App 內派送按鍵、不走 CGEvent |
| 16 | 網頁卸載後程式代送不丟泡泡 | `991cb63` | C | 卸載後代送：網頁建回、畫面有該則；拿掉修正的對照組網頁不回來 | 可驗；`native.sh C16`（EXAM_APP=） |
| 17 | 卸載中串流切回不重複 | — | C | 網頁卸載後代送；紀錄先含完整回答，再串流 10 段；唯一字串只出現 1 次 | 可驗；`native.sh C17`（EXAM_APP=） |
| 18 | 程序被主動關掉時沒確認的訊息放回 | — | C | 假 claude 不回送；送出後 terminate＋重開：unacked 清掉、寄件匣留 1 筆、原文回輸入框 | 可驗；`native.sh C18`（EXAM_APP=） |
| 19 | 大訊息寫入不卡主執行緒 | — | C | 不讀 stdin 的假 claude＋120 KB 訊息：排在第 6 秒的動作 12 秒內跑；改前版本拖到假 claude 結束 | 可驗；`native.sh C19`（EXAM_APP=） |
| 20 | 分支聊天室 MCP 精簡參數、不帶 --chrome | — | C | 假 claude 記下啟動參數：沒設＝帶 --chrome 無 MCP 參數；lite＝--strict-mcp-config＋只含 deja 的 --mcp-config、無 --chrome；none＝空 mcpServers；full 同沒設 | 可驗；`native.sh C20`（EXAM_APP=） |
| 21 | 建區不刪別人的同名組、刪組清涵蓋清單 | — | C | 測試資料造兩個總指揮；c1 建 c2 底下的同名同父區：失敗且該組仍在；removeGroup 後涵蓋清單無失效 id | 可驗；`native.sh C21`（EXAM_APP=） |
| 22 | send --wait 等到 timeout、不 15 秒就叫人重送 | — | C | 把 send 換成永遠不回；--wait --timeout 20：回應不早於 20 秒，且訊息含「不要重送」 | 可驗；`native.sh C22`（EXAM_APP=） |
| 23 | 額度重置日期跨年選對年 | — | C | 假的「現在」：12/30 讀 Jan 1 → 明年；1/2 讀 Dec 31 → 去年；同年照舊 | 可驗；`native.sh C23`（EXAM_APP=） |
| 24 | 看板壞一筆只跳過那筆 | — | C | collab.json 放 2 好 1 壞目標：讀到 2 個、原檔不動（舊版整個目標區變空） | 可驗；`native.sh C24`（EXAM_APP=） |
| 25 | 開 Big5 檔不改就換檔，原檔不被改寫 | — | C | 開 Big5 檔、走下拉選檔路徑換到別的檔：Big5 檔位元組不變（舊版變 UTF-8、多出幾個 byte） | 可驗；`native.sh C25`（EXAM_APP=） |
| 26 | 聊天網頁程序崩潰後自動重載 | — | C | 殺掉該格的 WebContent 程序：8 秒內 ready 重新成立（累計 2 次）；舊版不重載 | 可驗；`native.sh C26`（EXAM_APP=） |
| 27 | 看板開著、資料很多時按 F4 一秒內收完、不卡頓 | — | C | 120 個很長的目標＋右欄看板；--right-stall-probe 按 F4：1 秒內收完、主執行緒最長停頓 < 100ms（修前 150～180ms） | 可驗；`native.sh` |
| 28 | 公版匯出目的地防呆、刪太多檔停下 | — | 腳本 | 暫存資料夾＋假 HOME：非空非 repo／家目錄／別人的 repo 都拒絕且檔案還在；新資料夾與 codenv-public remote 可同步；要刪 40 個檔停下，調高門檻才放行 | 可驗；`export-guard.sh C28` |
| 29 | 沙盒讀鑰匙圈卡住時逾時回 nil | — | C | security 換成睡 30 秒的假腳本：keychain() 逾時（2 秒）回 nil，整體 6 秒內回來 | 可驗；`native.sh C29`（EXAM_APP=） |
| 30 | 更新檢查連到不回應的伺服器會逾時 | — | C | 本機假伺服器收連線不回；逾時縮成 3 秒，探測要回「連線逾時」（舊版永遠卡住） | 可驗；`native.sh C30`（EXAM_APP=） |
| 32 | codenv-todo 很長的請求不被截斷 | — | C | 送 3 萬中文字（約 90 KB）的請求：伺服器讀到換行邊界並正常處理；超過 8 MB 或未完整封包回 JSON 錯誤 | 可驗；`native.sh C32`（EXAM_APP=） |
| 33 | 檔名以 - 開頭的程式檔不被當成編譯選項 | — | C | -Wall.cpp 做 F9 檢查通過，執行指令用 ./-Wall.cpp | 可驗；`native.sh C33`（EXAM_APP=） |
| 34 | 排程防重送標記含年份 | — | C | 同排程 2026／2027 年 3/5 09:00 的標記不同（舊版相同） | 可驗；`native.sh C34`（EXAM_APP=） |
| 35 | 闔蓋外接螢幕：防抖、上限、虛擬螢幕不算 | — | C | 假環境：外接掉 2 秒不撐著、掉久才撐；外接闔蓋撐到上限放掉預擋且不主動睡；虛擬／未知廠商／內建／睡眠螢幕不算實體外接 | 可驗；`native.sh C35`（EXAM_APP=） |
| 36 | 桌寵進度通知極端數字不崩潰 | — | C | total／done／eta 塞 NaN、無限、1e30 並走到 items()：不崩潰（舊版 eta 1e30 在 items() trap） | 可驗；`native.sh C36`（EXAM_APP=） |
| 37 | 網頁程序反覆崩潰時重載有次數上限 | — | C | 1 分鐘內連殺 5 次：只自動重載 3 次（ready 累計 4 次），之後不再重載 | 可驗；`native.sh C37`（EXAM_APP=） |
| 38 | 闔蓋外接螢幕：睡醒寬限、重擋失敗放舊連線 | — | C | --lid-sim jump=40 模擬睡醒：有寬限記錄且在撐著之前；狀態確認後重擋失敗：送 off 並記舊連線已放掉 | 可驗；`native.sh C38`（EXAM_APP=） |
| 39 | 拖放暫存清理不刪草稿還指著的檔 | — | C | 暫存資料夾：舊且沒引用→刪、舊但草稿 JSON 引用（斜線被轉義）→留、新→留 | 可驗；`native.sh C39`（EXAM_APP=） |
| 40 | 背景 git 狀態讀對、逾時整群砍 | — | C | 大小相同內容不同的修改偵測到；CRLF＋eol=crlf 的 repo 無假變更；假 git 忽略 TERM 並留子程序：逾時後整群被砍、無殘留（filter 是否執行不斷言，已知限制） | 可驗；`native.sh C40`（EXAM_APP=） |
| 41 | 每週排程 weekdays 含 0／8 不崩潰 | — | C | weekdays 含 0、負數、8、空：summary 不崩潰，超出範圍的濾掉（舊版 0 越界崩潰、8 顯示成「日」） | 可驗；`native.sh C41`（EXAM_APP=） |
| 42 | 換模型交接遇大紀錄檔 | — | C | 約 70 MB 假紀錄：主執行緒只讀檔尾、交接有最後一段；全文檔先寫檔尾版，背景補成完整版（有最早的一句與讀過的檔） | 可驗；`native.sh C42`（EXAM_APP=） |
| 43 | 看板陣列混壞元素 | — | C | goals／steps 混入字串、數字：新增／改狀態不丟光其他元素、寫回前留 .bak；goals 不是陣列時不寫；讀取時不崩潰（isValidJSONObject） | 可驗；`native.sh C43` |
| 44 | state.json 與備份都解不開 | — | C | 原檔與 .bak 位元組不變、另存「讀不到」；對照：舊版最少欄位的檔讀得進來 | 可驗；`native.sh C44` |
| 45 | 缺鍵 decode 快照＋sprint 另存 | — | C | WakeSchedule／SprintState 必填欄位清單快照（新增非 Optional 欄位會讓它變）；sprint.json 讀不懂另存一份 | 可驗；`native.sh C45` |
| 46 | 預擋失敗背景重試 | — | C | 假環境：預擋失敗只記一次，小幫手恢復後背景重試成功 | 可驗；`native.sh C46` |
| 47 | 測試實例隔離與 --test-screen | — | C | CODENV_STATE_DIR／COLLAB_FILE／BROWSER_DIR 指到測試資料夾；--state-dir 缺值 exit 2；--test-screen 擺進指定螢幕 | 可驗；`native.sh C47` |

第 13～15 題雖比 A／B 貴，但能防住丟資料與核心操作回歸，適合留在規則減肥的最後一道驗證。


## A 類案例：具體測試草稿

原則：載入**實際被測檔案／函式**，不用另寫一份相同演算法當答案。JS 可沿用目前 `vm` 測法；Python 可用 `SourceFileLoader` 載入無副檔名 CLI，對檔案、時鐘、程序與 socket 做替身。不要呼叫會啟動 runner、App 或網路的 `main()`。

### A01：函數圖比例

本輪固定考卷；舊版會失敗：**是**。`a657704^`、`9457591^` 的實際曲線寬高比皆約 2.686。

入口：`wbPlot.svg()`，沿用 `scripts/test-plot.mjs` 的 SVG path／刻度解析。

| 輸入 | 預期 |
|---|---|
| 上下兩條 `±sqrt(25-x^2)`，x/y 都 `-6..6`，`aspect: equal` | 曲線總寬／總高與 1 差 `<0.02` |
| `y=abs(x)`、x `-3..3`、y `-1..3`，省略 aspect | 採等比例；相鄰 x/y 網格間距差 `<0.05px` |
| 同上加 `aspect: free` | 不採等比例 |
| `y=x^3`、x `-5..5`，省略 aspect | 極端範圍採填滿，不能把內容壓成一條細線 |

現有測試已涵蓋；固定考卷可直接抽出這些斷言。

### A02：定義域端點細分

本輪固定考卷；舊版會失敗：**是**。原草稿的 `-6..6` 恰好命中舊版 1,200 等分取樣點，單獨使用時舊版也通過；固定考卷新增 `x: -6.01..6.02`，`a657704^` 左端差 5.56px，現版兩端皆小於 1.5px。不傳入舊版尚不支援的 aspect 語法，避免以解析失敗冒充端點 bug。

輸入：

```text
y = sqrt(25 - x^2)
y = -sqrt(25 - x^2)
x: -6..6
y: -6..6
aspect: equal
```

預期：兩條 path 左端及右端距離分別 `<1.5px`。同時加入反例 `1/x` 與 `floor(x)`：零點／階梯不得被細分連成跨越不連續點的線；SVG 不得包含 `NaN`／`Infinity`。現有測試已涵蓋。

### A03：內部附加行與引用解析

本輪固定考卷；舊版會失敗：**是**。`e93a637^` 的實際 chat.js 歷史泡泡漏出程式碼區標記；不是只驗新版 quote.js。

入口：`Resources/chat/quote.js` 的 `parse()`；另沿用 `quote-test.js` 的最小 DOM 驗歷史接線。

| 輸入 | 預期 |
|---|---|
| `問題\n\n〔codenv 程式碼區〕a.swift` | `text === "問題"` |
| 分別改成「聊天室名稱」「換模型」 | 同上，`quotes` 為空 |
| 正常問題＋完整引用區塊＋上述附加行 | 問題保留，引用依對話順序還原，內部附加行不顯示 |
| 引用缺結束標記／缺 `ref:` | 不丟例外、不產生假引用 |
| 21 個家庭 emoji 的 preview | 20 個完整 grapheme，不切碎 |

現有 `quote-test.js` 已涵蓋主要情形。

### A04：手機 Markdown 不掛住、不執行 HTML

入口：phone 分支 `Resources/remote/md.js` 的 `mdToHtml()`。

| 輸入 | 預期 |
|---|---|
| 單獨三反引號 | 正常返回 codeblock，不無限迴圈 |
| 帶 `js title=x` 的圍欄、四反引號圍欄 | 正常返回，內容存在 |
| `<script>alert(1)</script>` | 無可執行 `<script>` |
| `[a](javascript:alert(1))` | 無 javascript href |
| `![x](http://evil/x.png)` | 不產生會載遠端圖的 `<img>` |
| 表格 | 有 `tablewrap` |

保留既有 seed `12345` 的 20,000 筆 fuzz；由父程序設整體 timeout，避免同一 JS 執行緒卡住後 timeout 也失效。現有測試存在於 phone，未在本次執行。

### A05：精準撤泡泡

本輪固定考卷；舊版會失敗：**是**。`122e79d^` 沒有撤泡泡機制，以泡泡仍存在的行為斷言驗出。現版另驗非最後一則 UUID、重複撤送與引用保留；原生回復不在本題範圍。

沿用 `quote-test.js` 的最小 DOM：

```js
wb.restoreQuotes([{ qid: 'u1', role: 'user', text: '來源' }]);
wb.localUser({ uuid: 'failed', text: '送失敗' });
wb.localUser({ uuid: 'other', text: '另一則' });
wb.unsend('failed');
```

預期：

- `failed` 不存在，`other` 仍存在。
- 引用選取仍含 `u1`。
- 重複撤同 UUID 不丟例外、不影響其他訊息。

現有測試已驗同類 UUID 撤除；這只能證明前端，不能取代原生送出失敗回復測試。

### A06：含分隔符的選擇題

本輪固定考卷；舊版會失敗：**是**。`bfbe834^` 實際 AskCard.render 的 chosenSet 接線拆散含頓號的選項；固定考卷也涵蓋英文逗號、其他文字與前綴選項。此題為 VM 純邏輯；額外的 B 類選項勾選畫面草稿未實作。

入口：`J/chat.js` 的 `splitChosen()`，可抽函式到 VM，實際載入原碼。

| chosen | labels | 預期 |
|---|---|---|
| `紅、綠、藍` | `["紅、綠","藍"]` | `["紅、綠","藍"]` |
| `A, B, C` | `["A, B","C"]` | `["A, B","C"]` |
| `甲、乙、其他文字` | `["甲","乙"]` | `["甲","乙","其他文字"]` |
| `甲乙、甲` | `["甲","甲乙"]` | `["甲乙","甲"]` |

再加 B 類 UI 接線驗證：既有選項被勾選，不落入「其他」。

### A07：看板步驟負責人解析

本輪固定考卷；舊版會失敗：**是**。`593aaf7^` 實際 parse_step 把 `a@b.com` 拆為 owner `b.com`。

入口：`scripts/codenv-todo` 的 `parse_step()`；固定 `new_id()`、`now()`，比較 text／owner。

| 輸入 | 預期 |
|---|---|
| `聯絡 a@b.com` | 全文保留，無 owner |
| `檢查 @State 宣告` | 全文保留，無 owner |
| `修正 @gemini3.8flash` | text 為 `修正`，owner 為 `gemini3.8flash` |
| `修正@gemini3.8flash` | 相容既有已知 owner 寫法 |
| `聯絡 a@b.com`，`split_owner=False` | 原文保留；外層顯式 owner 不被內容覆蓋 |

### A08：HANDOFF 後仍有補充

本輪固定考卷；舊版會失敗：**是**。`593aaf7^` 實際 finish 把 HANDOFF 後有補充的 need-user 判成 done；目前版也驗最後有效 HANDOFF 與非行首文字。

入口：實際 `AgyRunner.finish()`；以替身收集 `set_final()` 的狀態、note、結果文字，禁止啟動程序或寫真檔。

| stdout | 預期 |
|---|---|
| `內容\nHANDOFF: need-user 等確認\n補充說明` | 狀態為需使用者處理；補充說明仍留結果 |
| `HANDOFF: done\n補充\nHANDOFF: stuck 缺檔\n尾註` | 採最後有效 `stuck` |
| 普通文字、無 HANDOFF | 沿用預設 done |
| 內容中非行首的 `提到 HANDOFF: stuck` | 不當控制狀態 |

不能只測一段新 regex；要檢查實際 finish 最後送出的狀態與結果。

### A09：CLI 終端輸出控制字元

入口：`scripts/codenv-browser` 的 `main(["text"])`；mock `ask()` 回傳資料，捕捉 stdout。

輸入 title／url／text 含 `ESC ]52`、BEL、DEL、C1 控制字元，以及換行、tab、中文。

預期：ESC、BEL、DEL、C1 被替換成可見替代字元；換行、tab、中文保留；標題與網址也套相同清理。不連 socket。

### A10：連續額度退回計數

入口：`AgyRunner.finish()` 額度分支；替身提供同一步驟，連續呼叫。

輸入：連續四次真正的 stderr 額度錯誤。

預期：`quotaBack` 依序為 1、2、3、4；第 4 次進 blocked，不再無限退回。成功／普通完成的分支不得把既有計數意外清掉。此題同時追蹤 `4f7b4fb` 與 `52279dd`。

### A11：額度判斷只看正確來源

本輪固定考卷；舊版會失敗：**是**。`52279dd^` stdout 審查文字導致退回 todo。固定考卷也驗 stderr／agy log 正向 quota、退還開始日；尚未涵蓋所有取消／啟動失敗跨午夜組合。

入口：`AgyRunner.finish()`；mock stdout、stderr、agy log、quota 判讀與狀態寫入。

| 輸入 | 預期 |
|---|---|
| stdout 是審查文字 `429 rate limit quota`；stderr／log 空 | 不因回答文字而暫停／退回 |
| 非成功完成，stderr 是真正額度錯誤 | 計入 quotaBack、按規則退回／暫停 |
| exit 0 且有有效 `HANDOFF: done`，回答提額度 | 正常完成 |
| 程序啟動失敗／取消，且跨午夜 | 只退還開始日的次數，不扣／退錯日期 |

### A12：暫存工作區與環境白名單

本輪固定考卷；舊版會失敗：**是**。`52279dd^` 接受假 TMPDIR 的非暫存子路徑。現版另驗真正暫存子路徑、拒絕根目錄，以及實際 launch 的環境白名單；Popen 為替身。

入口：`is_temp()`、`AgyRunner.start()` 的環境組裝；mock `os.confstr()`、`realpath()`、`Popen`。

| 輸入 | 預期 |
|---|---|
| 呼叫者 TMPDIR 指向非暫存資料夾 | 不因此讓該資料夾通過 `is_temp()` |
| 真正 `/private/tmp/某子目錄` | 通過 |
| `/private/tmp/` 根本身 | 不當作允許的工作子目錄 |
| ENV 含 PATH、HOME、LANG、LC_ALL、SECRET_TOKEN | 啟動環境保留允許值及 LC_*，沒有 SECRET_TOKEN；TMPDIR 來自系統／本次專用目錄 |

### A13：睡眠後心跳過期不誤殺

入口：`any_alive()` 與 `wait_cmd()` 的過期判斷。

輸入：心跳超過上限，runner 或 agy PID 仍存在；`os.kill(pid, 0)` 分別返回成功、丟 PermissionError、ProcessLookupError。

預期：成功／PermissionError 都算活著，不改 blocked；全部不存在才走中斷恢復。全程 mock `os.kill`，不對真程序送訊號。

### A14：步驟 ID、沙箱與寫入順序

| 實際入口／輸入 | 預期 |
|---|---|
| `AgyRunner.start()`，ID `../x`、含 `/`、非六位 hex | 在啟動／組結果路徑前拒絕 |
| ID `a1b2c3` | 格式通過 |
| `sandbox_profile()` | profile 含對 launchctl、open、osascript、tmux、screen 的執行拒絕；這是產生器測試，不能宣稱驗了 OS enforcement |
| `edit()`，mock 檔案 API 記錄順序 | 寫入→flush→fsync→rename；rename 前保留既有檔備份 |

### A15：壞看板與 CLI 逾時

入口：`load()`、`edit()`、`codenv-browser.ask()`；使用 in-memory 檔案／socket 替身。

| 輸入 | 預期 |
|---|---|
| collab 為空字串、非法 JSON、`[]` | 明確 CollabFileError；原始 bytes 不變 |
| collab 只有 goals、沒有 items | 不因缺 items 而 KeyError |
| flock／寫入失敗 | 不回成功、不覆蓋原檔 |
| socket.recv 丟 timeout | 有可理解錯誤，socket 關閉，沒有無限等待 |

### A16：截圖預設檔名不覆蓋

入口：`codenv-browser.main(["shot"])`；mock `ask()`、暫存檔產生器及寫入 API。

輸入：連續兩次相同圖片回應，不指定 `-o`。

預期：目的路徑不同；第一次內容未被第二次覆蓋。指定 `-o` 的行為另外驗，不混入預設檔名題。

### A17：i18n 盤點忽略註解

入口：`i18n-report.py` 的 `js_keys()`；mock 讀取 `chat.js` 的內容。

輸入：

```js
// L('註解甲')
/* L('註解乙') */
L('實際字串');
```

預期：只回收 `實際字串`。另加「字串內含 `https://`」的反例，避免去註解時誤刪實際字串。

`i18n-verify.py` 的用途是移除 `L()/LV()` 包裝後與 HEAD 比較；**不能拿它通過當作翻譯完整、JS parser 正確或 UI 無回歸的證明**。

### A18：release 中文緊接變數的靜態回歸

不執行 release。Python 只讀 `release.sh`、`public/release-public.sh` 的訊息行。

輸入：修正前樣本 `$DMG（…）`、`$DEST（…）`，及修正後樣本 `${DMG}（…）`、`${DEST}（…）`。

預期：靜態檢查拒絕「未加大括號變數緊接中文／全形括號」的已知錯誤形態，接受修正形態。此題只保護該次插值問題，不證明打包或私人路徑掃描成功。

## B 類案例：具體測試草稿

共同方式：headless 瀏覽器載入本機 `Resources/chat/test.html`，禁止非本機資源請求。使用實際 `window.wb` 注入事件；斷言 DOM、貼底距離及 `window.__posted`。每題從乾淨頁面開始，避免重播資料互相污染。

### B01：未完成串流的數學式

本輪固定考卷；舊版會失敗：**無法驗**。已以 `git show 8cd5f38^:Resources/chat/chat.js` 取出，但本環境禁止套用離線 sandbox（sandbox_apply EPERM），亦曾禁止 Node 監聽本機 TCP。測試已實作串流 final 前／後對照；需在允許 sandbox-exec 與本機 TCP 的終端重跑。

測試頁：

```text
Resources/chat/test.html?bare=1&math=1&final=0&fast=1
```

等待 `window.__done === true`。

預期：

- 尚未送 final assistant／result 就有 5 個 `.katex`。
- 不顯示 `WBMATHPLACEHOLDER`。
- 價格 `$5 和 $10` 保留文字。
- 無 JS page error；頁面不因缺 `quote.js` 空白。

再用 `final=1` 跑對照：完成後公式數量維持，沒有重複公式或殘留 caret。

### B02：中文路徑、裸路徑與單一波浪號

輸入一則 assistant：

```text
看 ~/專案/中文.swift，還有 `/tmp/a.txt`，單一 ~ 要保留。
```

預期：中文／絕對路徑產生路徑節點，點擊產生正確 `__posted` 路徑訊息；單一 `~` 不產生 `<del>`。

相對檔名再注入 `wb.pathsChecked()` 的存在／不存在結果：存在才變可點路徑。此題不開 Finder。

### B03：思考不重複

輸入事件序列：

1. thinking block start。
2. 兩段 thinking delta：`先看`、`程式`。
3. 完整 assistant thinking：`先看程式`。
4. block stop／result。

預期：只有一份 thinking 內容，文字不變成 `先看程式先看程式`，沒有兩張思考卡。可再接下一則 message ID，確認兩輪沒有共用卡片。

### B04：瀏覽器夾位置不等於使用者上捲

本輪固定考卷；舊版會失敗：**無法驗**。已取出 `a70357d^`；同為 sandbox_apply EPERM，尚未驗證斷言。測試含真實排版夾位、無操作不解除追隨、CDP 真滾輪及恢復追隨。

輸入：足夠長歷史，貼底並 `setBusy(true)`；讓末段內容先縮短、再增長，全程沒有 wheel／鍵盤／pointer 輸入。

預期：排版穩定後離底 `≤2px`，`__posted` 沒有誤報使用者解除追隨。

對照：用 headless 真正的 mouse wheel 往上，再追加內容；畫面保持閱讀位置，不被拉回底。

### B05：送出扣住貼底，使用者操作才解除

輸入：長歷史→`wb.localUser()`→`wb.setBusy(true)`→連續追加多段 assistant 內容。

預期：每次穩定後貼底。再往上 wheel／PageUp，追加內容不得強拉到底；執行 `wb.scrollEdge(false)` 回到底後恢復追隨。

### B06：工具框內與整頁都追新內容

輸入：Bash tool_use 後逐段增加多行輸出；另跑 growing thinking 情境。

預期：

- 自動展開時，框內 `scrollHeight-scrollTop-clientHeight` 接近 0。
- 整頁原本在底時仍貼底。
- 使用者已往上讀時，不自動拉整頁。
- result 後按規則收合，沒有突然跳到錯誤位置。

### B07：自動展開、人工選擇與長行換行

| 輸入 | 預期 |
|---|---|
| 即時 tool／thinking start | 自動展開 |
| 完成事件 | 自動收合 |
| 進行中使用者親自切換開關，再完成 | 保留人工選擇 |
| 歷史載入已完成工具 | 不當作即時工具自動展開 |
| 2,000 字無空白輸出／code／diff | 不撐出頁面水平捲軸；內容可讀 |

### B08：工具結果的遠端圖片不自動載入

輸入：工具結果同時包含 `https://example.invalid/private.png` 與本機圖片表示。

預期：遠端圖變成連結說明，沒有對應的自動載圖 `<img src="https://…">`；攔截器記錄的遠端請求數為 0。本機圖片仍走本機圖片路徑。

這可測 `2be92cb` 的前端部分；不能取代 `LocalImages.swift` 的 symlink／圖片內容驗證。

### B09：Bash 非零 exit 顯示

輸入：Bash 結果含 `Exit code 1`，但沒有獨立的工具協定錯誤。

預期：保留 exit code 文字，不僅因非零代碼額外畫成工具錯誤紅叉。再加真正 `is_error` 的對照，確保錯誤資訊沒有一起消失。

### B10：未讀排隊訊息失敗狀態

本輪固定考卷；舊版會失敗：**無法驗**。已取出 `066d226^`；同為 sandbox_apply EPERM，尚未驗證斷言。測試含未讀／已讀、result 後退出、重複 flush 與精準刪除。

輸入：

```js
wb.history([]);
wb.localUser({ uuid: 'queued-1', text: '排隊內容', queued: true });
wb.flushQueued();
```

預期：該則有 `.lost` 與「沒送到」提示，刪除鈕只刪該則。

另測：

- 一輪 result 把 queued 移入對話，尚未 `userTaken()` 就退出：仍標 lost。
- 已 `wb.userTaken('queued-1')` 再退出：不得標 lost。
- 重複 `flushQueued()` 不重複加提示。

### B11：task notification 不冒充使用者

輸入 user 事件，內容為完整 `<task-notification>…</task-notification>`；另以 `history()` 載入同樣紀錄。

預期：即時與歷史都顯示成通知樣式，不產生一般使用者泡泡。普通 user 訊息仍正常；不能因一般文字提到 `task-notification` 就整則藏掉。

### C80：magpie 雙帳號三額度平均與 Argon 明細

輸入 `scripts/exam/dev/fixtures/magpie-accounts.json` 兩帳號 fixture，各自含 Gemini 5 小時、Gemini 每週及 Argon 每週額度。第二帳號使用 `Gemini 4 Argon` 的 pool 標籤，驗證型號標籤也能映射至 Argon bucket。

預期：池整體三欄平均為 `85／70／60%`，狀態列格式為 `85%  70%  阿公 60%` 且不含破折號；卡片可保留兩帳號各三項的個別值，Argon 合計採最早有效重置時間。執行器 `scripts/exam/logic.mjs C80 <repo>` 讀取 fixture，驗證 Magpie 欄位對應、平均、狀態列和 Swift UI 接線；不啟動 App。

### C81：右欄模式切換固定且數值欄對齊

原生 UI 案例（`scripts/exam/dev/cases.json` 登錄；目前 pending）。需在隔離測試 App 中載入至少一筆同時有記憶體與上下文數值的聊天室，分別擷取列表及關聯圖模式 accessibility 節點的 window frame：

| 節點 | accessibility identifier | 預期 |
|---|---|---|
| 模式切換群組 | `rightPanelModeToggle` | list／graph 的 x、y、width、height 完全相同 |
| 記憶體標題和值 | `rightPanelMemoryHeader`／`rightPanelMemoryValue` | 標題和值的右緣 x 差 ≤ 1 pt |
| 上下文標題和值 | `rightPanelContextHeader`／`rightPanelContextValue` | 標題和值的右緣 x 差 ≤ 1 pt |

另驗證列表標題上下文文字與切換按鈕 frame 左緣至少相隔 1 pt，且標題完整顯示。使用原生 accessibility frame（同一螢幕座標系）判定；不可用 DOM 代替 SwiftUI 座標。案例尚未接上 probe 前保持 pending，不視為通過。

### C82：右欄分界線固定聊天室標題並還原高度

原生 UI 案例（`scripts/exam/dev/cases.json` 登錄；目前 pending）。在隔離 `--state-dir` 測試實例中使用原生 accessibility frame 擷取聊天室標題列和模式按鈕的位置；新增／移除正在跑工作及切換列表／關聯圖後，標題列 `frame.origin.y` 必須一致。以拖曳手勢調整分界線，重載右欄並重開隔離實例後，讀回分界線高度，誤差需小於 1 pt。另檢查該值只寫入測試 suite，不污染正式 UserDefaults。Probe 尚未接上前維持 pending。

### B13：result 停止忙碌計時、背景通知不重啟

輸入：`wb.setBusy(true)` 等待計時器啟動後送 `result`，隨後送一筆含 `<task-notification>` 的完成通知。

預期：result 後 `.typing` 隱藏且計時字串清空；背景通知仍以通知樣式呈現，但不重新顯示忙碌列或開始累計時間。原生狀態追蹤也略過 `system/task_notification` 與標記式 user 通知，避免聊天室 idle 被拉回 working。
### B12：Codex interrupted 收尾解除生成狀態

模擬 Codex 串流已收到部分回答後，送出 `[Request interrupted by user]` 與 `result(error_during_execution)`，對應 app-server 的 `turn/completed` 狀態 `interrupted`。

預期：串流游標消失、生成狀態解除、已收到的部分回答保留。此瀏覽器案例只驗前端收尾；Codex JSON-RPC 的 thread／turn 參數與 mock app-server 中止回覆由 C65 覆蓋。

### C65：Codex turn/interrupt JSON-RPC 與 mock app-server 收尾

以假的 `codex app-server` 協定資料測試 `CodexBridge`：建立 thread、開始 turn，再呼叫 `interrupt()`。

預期：送出 JSON-RPC `turn/interrupt`，參數帶目前的 `threadId` 和 `turnId`；mock server 回覆中斷成功並送 `turn/completed(status: interrupted)`；Bridge 發出錯誤收尾 result，讓 `ChatSession` 回到 idle。Runner：`scripts/bridge-test/run.sh`。這是 Bridge 層覆蓋，沒有模擬原生視窗中的實體 Ctrl+C／停止按鈕操作。

## 保留組 C 類的最小重跑規格

這三題尚未執行；以下是日後接 runner 所需的具體操作與判定。

| 案例 | 輸入／操作 | 預期／現有入口 |
|---|---|---|
| 空檔與壞檔保護 | 分開建立空檔、非空非法 JSON、讀取失敗的 state／schedules；嘗試新增資料及結束存檔 | 空檔能恢復；損毀原檔 bytes 不變，新增不假報成功；用 `--state-dir`、`--schedule-put`、`--schedule-dump`，另比對檔案 |
| 遲到 save 不寫錯檔 | A、B 內容各不同；先開 A 再開 B；透過 `--codelab …:js=…` 投遞 `{type:"save",path:A,text:"late"}` | B bytes 完全不變，當前 file 仍 B；以 `open=`、`js=`、`ui` 掛鉤及磁碟比對驗收 |
| 編輯器快捷鍵不被攔 | 在程式碼區放焦點，聊天有灰字建議；逐一按 Tab、`/`、⌃C、⌃Enter；再把焦點放聊天做正向對照 | 編輯器操作不採用聊天建議、不送聊天、不停止聊天；聊天正向行為仍作用；現有 `edkey=` 只涵蓋部分，需補其餘按鍵斷言 |

所有 C 類 runner 應使用假 Claude／Codex／agy、本機網頁 fixture 與假用量；`--state-dir` 是資料隔離入口，**本身不是禁止外連或替換全部後端的保證**。本次僅完成盤點、離線既有 Node 驗證與案例草稿，沒有把掛鉤誤列為已通過的固定考卷。B12 驗 Codex interrupted 前端收尾，C65 驗 Codex JSON-RPC 與 mock app-server；兩題尚未執行。

### A20：代勾記錄來源聊天室與原話

驗證 `codenv-todo step <使用者步驟> 完成 --note "" --by <總指揮>` 必須同時有非空原話、總指揮名稱及有效的 `CODENV_CONVERSATION` UUID；只允許代勾 owner 為「你」的步驟。成功後記錄代勾人、原話和來源聊天室，並在最後一步完成時同步完成目標。拒絕路徑不得改動看板。Runner：`scripts/exam/todo.py A20 <repo>`。

### C66：待你處理收件匣操作與聊天室通知

驗證最左側協作圖示的收件匣只列提議、輪到使用者的「決定：…」及驗收步驟；同意提議、回覆決定、驗收通過與退回驗收均更新正確狀態。回覆及退回通知送到開目標的聊天室；找不到聊天室時依動作保留或記錄狀態並提示通知未送出。也覆蓋空收件匣、最後一步完成目標、非使用者步驟與發現不受影響。Runner：`scripts/exam/native.sh C66 <repo 根目錄>`。

### C67：沙盒聊天室專屬 token 分權

驗證沙盒聊天室 token 綁定來源 conv、限制可用命令、為 send 加入伺服器標記，並限制看板讀寫及衝突重試；正式 token 維持既有權限。Runner：`scripts/exam/native.sh C67 <repo 根目錄>`。

### A21：沙盒搜尋索引避開 AI 工作台並略過不可讀中繼資料

驗證沙盒索引寫入 Claude 可寫的 projects 子目錄，不讀取 AI 工作台的 state 與 transcripts；工作台中繼資料不可讀時，仍可建立 Claude 對話索引。Runner：`scripts/exam/todo.py A21 <repo>`。

### C72：F12 用量面板開關與焦點保留

以假用量啟動隔離實例，派送 F12 開啟面板、等待更新再關閉。預期面板可開關、開啟不搶焦點、用量有刷新，關閉後焦點仍在原處。Runner：`scripts/exam/native.sh C72 <repo 根目錄>`。

### C73：F1 說明介面載入、搜尋與關閉

以假用量啟動隔離實例，確認快捷鍵總表文件可載入和解析、搜尋可找到 F12 並排除不符頁面；F1 開啟不搶焦點，Esc 與再次按 F1 都可關閉且還原焦點。Runner：`scripts/exam/native.sh C73 <repo 根目錄>`。

### C74：用量紀錄去重、輪替與週期統計

以隔離 state-dir 驗證用量紀錄同值去重、重置週期變更仍新增、超過 5 MiB 輪替並限制舊檔大小；`codenv-todo usage-log` 以跨 cutoff baseline 及 resetAt 分段計算百分比／次數消耗。Runner：`scripts/exam/native.sh C74 <repo 根目錄>`；CLI 統計由 `scripts/exam/todo.py A22 <repo>` 覆蓋。
