# 聊天介面：Swift 和網頁畫面之間的約定

AI 工作台的對話改成聊天介面：Swift 端用 `claude -p --input-format stream-json --output-format stream-json
--include-partial-messages --verbose --permission-prompt-tool stdio --session-id/--resume <id>` 跑 Claude，
把它吐出來的每一行 JSON 原封不動交給網頁畫面（WKWebView）去畫。輸入框是原生的（不在網頁裡）。

## 檔案

- `Resources/chat/index.html`、`chat.css`、`chat.js`：畫面本體。不能連網，用到的函式庫放 `Resources/chat/vendor/`。
- Swift 用 `loadFileURL(index.html, allowingReadAccessTo: Resources/chat)` 載入。

## Swift → 網頁（呼叫全域物件 `wb` 的函式，參數都是 JSON）

| 函式 | 意思 |
|---|---|
| `wb.setTheme({fg, bg, ansi:[16 個 #RRGGBB], monoFont, monoSize, dark})` | 配色、等寬字型（來自 iTerm 設定）。內文用系統字型。可能隨時再叫（切換深淺色） |
| `wb.history([記錄, …])` | 接回舊對話時，先把 `~/.claude/projects/<專案>/<id>.jsonl` 裡的記錄整批給你（每筆是一行解析後的物件）。只畫 `type` 為 user／assistant 的，其餘略過 |
| `wb.event(物件)` | 即時收到的一行 stream-json（見下面「事件」）。照順序呼叫 |
| `wb.localUser({text, images:[data URL]})` | 使用者剛送出的訊息，馬上畫出來（Claude 不會回送使用者訊息） |
| `wb.permissionResolved(request_id)` | 這個權限／選擇題已經處理完（例如被中斷），把卡片收起來 |
| `wb.setBusy(true/false)` | Claude 正在工作／停下 |
| `wb.notice(text)` | 一行系統提示（例如「Claude 結束了，按送出會重新接上」） |

## 網頁 → Swift（`window.webkit.messageHandlers.wb.postMessage(物件)`）

| 物件 | 什麼時候 |
|---|---|
| `{type:"ready"}` | 網頁載好，可以開始呼叫 `wb.*` |
| `{type:"permission", request_id, behavior:"allow", updatedInput, updatedPermissions?}` | 按「允許」。`updatedInput` 原樣帶回請求裡的 `input`。按「這次對話都允許」時把請求的 `permission_suggestions` 放進 `updatedPermissions` |
| `{type:"permission", request_id, behavior:"deny", message}` | 按「拒絕」，`message` 例如「使用者拒絕」 |
| `{type:"answer", request_id, updatedInput}` | AskUserQuestion 答完：`updatedInput` = 原本的 `input` 再加 `answers: {"題目原文": "選的 label"}`（多選用「、」連起來；「其他」就放使用者打的字） |
| `{type:"open", path}` / `{type:"openURL", url}` | 點了檔案路徑／連結 |

## 事件（`wb.event` 收到的東西）

實際樣本：`scratchpad/chat-probe/events*.jsonl`（一般、權限、選擇題各一份）。重點：

- `{"type":"stream_event","event":{...}}`：Anthropic 串流事件。`content_block_start`（`content_block.type` 是 text／thinking／tool_use）、`content_block_delta`（`delta.type` 是 `text_delta`／`thinking_delta`／`input_json_delta`）、`content_block_stop`、`message_start`、`message_stop`。用來讓文字一個字一個字流出來。
- `{"type":"assistant","message":{"id",...,"content":[一個區塊]}}`：一個區塊完成後的完整版。**同一個 message.id 會來好幾次，每次一個區塊**（text、thinking、tool_use）。拿它取代串流中暫時畫的內容。
- `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id","content","is_error"}]},"tool_use_result":...}`：工具的結果，接到對應的工具卡片上。
- `{"type":"control_request","request_id","request":{"subtype":"can_use_tool","tool_name","input","description","permission_suggestions","tool_use_id"}}`：要權限。`tool_name` 是 `AskUserQuestion` 時是選擇題（`input.questions[]`：question、header、options[{label,description}]、multiSelect）。
- `{"type":"result",...}`：這一輪結束（`is_error`、`total_cost_usd`、`duration_ms`）。
- `{"type":"system","subtype":"init"|"status"|"hook_started"|...}`：大多不用畫。`subtype:"permission_denied"` 可以畫成一行小字。
- `parent_tool_use_id` 不是 null 的事件屬於子代理（Task 工具）：畫在那張 Task 卡片裡面，或縮排。

## 長相與手感

- 像 Claude 桌面版／Codex：使用者訊息靠右或有底色的泡泡；Claude 的回覆不加框、整段排版；Markdown（標題、清單、表格、引用、程式碼區塊上色、行內程式碼）。介面文字用繁體中文。
- 捲動：瀏覽器原生的平滑捲動。Claude 在輸出時自動跟到底；使用者往上捲就不跟，右下角出現「↓ 最新」按鈕。
- 工具卡片：一行摘要（例如「執行 `npm test`」「讀取 src/app.ts」「編輯 Store.swift（+3 −1）」），點開看細節／結果；Edit 顯示紅綠 diff；Bash 顯示指令和輸出（ANSI 顏色可略過）；TodoWrite 顯示清單；錯誤結果標紅。
- 思考（thinking）：收成一行「思考中…」／「想了 N 秒」，點開看內容（內容常是空字串，那就不要能點開）。
- 權限卡片：寫清楚 Claude 要做什麼（工具＋參數摘要），按鈕「允許」「這次對話都允許」（有 permission_suggestions 才出現）「拒絕」。
- 選擇題卡片：每題一組選項（單選／多選），外加「其他…」可以打字，一個「送出答案」。
- 深色、淺色都要好看；顏色從 setTheme 來（背景、文字），強調色可以用 ansi 裡的藍。

## 網頁端補充

以下是網頁端（`Resources/chat/`）做的時候補上的細節，上面的函式名稱與訊息格式都沒有改。

- **多一個 `wb.clear()`**：清空畫面和內部狀態（換對話時可用）。`wb.history()` 本身也會先清空再畫。`wb.event()` 收字串也可以（會自己 `JSON.parse`）。
- **權限卡片按下去就收起來**：按「允許／拒絕」後卡片直接移除，結果留在對應的工具卡片上（拒絕會標「已拒絕」）。Swift 不必再呼叫 `permissionResolved`，叫了也沒關係。工具結果先到的話卡片也會自己收掉。
- **「這次對話都允許」的字樣**：`permission_suggestions` 裡只要有一項的 `destination` 不是 `session`（例如 Bash 的 `addRules` 會是 `localSettings`，會寫進專案設定、之後的對話也算），按鈕就改叫「以後都允許」，並在上方寫出會記住什麼（例如 `Bash(python3 calc.py)`）。送出的訊息一樣是 `updatedPermissions: permission_suggestions`。
- **選擇題的「略過」**：除了「送出答案」，還有一個「略過」，送的是 `{type:"permission", request_id, behavior:"deny", message:"使用者略過了這個問題…"}`。「其他…」打的字在多選時和其他選項一起用「、」接起來。
- **停止**：收到 `user` 事件內容是 `[Request interrupted by user]`（或 `… for tool use]`）時畫一行灰色小字「已停止」，接著的 `result`（`error_during_execution`、`is_error:true`）不會畫成紅色錯誤，只在結尾寫秒數。`setBusy(false)` 時還在「思考中…」的區塊會收成「想了 N 秒（已停止）」。
- **thinking_tokens**：`system/thinking_tokens` 會在「思考中…」旁邊顯示「約 N token」。
- **`open` 的 path 一律是絕對路徑**：相對路徑用 `system/init`（或舊記錄裡的 `cwd`）解析，`~/` 展開成你的家目錄，結尾的 `:行號` 會去掉。可點的地方：工具卡片標題裡的檔名、Markdown 連結、看起來像路徑的行內程式碼。`http(s)`／`mailto` 連結送 `openURL`。
- **安全**：Claude 輸出裡的 HTML 一律當文字顯示（只放行 `<br>`、`<kbd>`、`<sub>` 這類沒有屬性的單一行內標籤），`javascript:` 連結不會變成連結；`index.html` 用 CSP 禁止頁面內嵌 script。Swift 用 `evaluateJavaScript` 呼叫 `wb.*` 不受影響。
- **子代理**：Task 工具在現在的 CLI 叫 `Agent`，兩個名字都當子代理卡片。子代理的事件沒有串流（只有完整的 assistant／user），卡片標題會顯示最新一步；結果優先用 `tool_use_result.content`（`tool_result.content` 前面包著一段 `[Subagent hand-back]` 說明）。
- **舊對話（history）**：略過 `isMeta`、`isSidechain`，空白的 thinking 不畫；`<command-name>` 畫成「/指令」泡泡、`<local-command-stdout>` 畫成灰色提示；沒有結果的工具顯示「已停止」，不會一直轉圈。
- **步驟組（自動收合）**：一輪裡連續的工具卡片＋思考列（中間沒有文字段落）包成一組 `.grp`。進行中逐條顯示；後面接上文字、選擇題、提示，或 `result`／`setBusy(false)` 時收成一行摘要（「執行了 N 個指令、讀了 N 個檔案…」，讀／改／建立按不同檔案算；有失敗或拒絕標紅），點一下展開／收起。只有一步的組收起時就是那一步本身（思考列藏起來）。組裡有工具在等允許（或一輪還沒結束時還在跑）就不收。權限卡片、選擇題、計畫（ExitPlanMode）不收進組；子代理裡面不分組。`wb.history` 載入的組一律收起；`wb.historyAppend` 最後一組若還沒結束就保持展開。
- **收合不拉動捲動位置**：跟到底時收完再貼底；組的頂端在畫面上方時補回高度差；使用者往上捲、組就在眼前、而且收起後頁面會短到被往下拉時，先不收，等他捲走或回到底部再收。使用者自己點開摘要時不會被「跟到底」帶走。
- **測試頁**：`test.html` 自帶樣本資料（真實 stream-json 樣本＋幾段合成的：停止、TodoWrite、待處理的權限與選擇題），網址參數 `?theme=light`、`fast=1`（不等時間）、`bare=1`（不顯示測試按鈕）、`open=1`（全部卡片展開）、`long=300`（300 輪舊對話測效能）、`stopAt=N`（重播到第 N 個事件停住）、`steps=1`（把合成的一長串工具步驟當即時事件重播，測步驟組；預設情境也會用 `historyAppend` 接上同一份樣本）。build.sh 已排除 test.html，其他檔案都要進 App。
