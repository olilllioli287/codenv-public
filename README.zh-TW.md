# codenv

一個 macOS App，把 Claude Code 放進一個像聊天軟體、又能像終端機一樣分格的視窗裡。側欄管理專案和對話，右邊可以把聊天室、終端機、網頁並排切成好幾格，讓好幾個 AI 一起工作。

目前以 Claude Code 為主，也可以接 Codex、GitHub Copilot、Apple 內建模型和本機 MLX 模型。

> codenv 是個人專案，跟 Anthropic、OpenAI、GitHub、Google 都沒有關係。

## 現在做了什麼

**聊天與對話**
- 每個聊天室都是一段真正的 Claude Code 對話（`claude -p` 的 stream-json 模式），畫面是聊天介面：Markdown、程式碼上色、工具步驟、權限與選擇題卡片都直接畫出來。
- 輸入框支援貼圖、拖檔案。圖片和檔案會變成輸入框上方的卡片（檔案顯示副檔名，資料夾顯示資料夾圖示），文字裡的路徑可以整塊刪、整塊跳過。
- 對話裡的檔案路徑可以點，點了在 Finder 裡選起來。中文檔名、沒包反引號的路徑都認得。本機圖片會直接顯示，載不到的改成文字，不會出現破圖。
- 換模型時，自動把前面的對話交接給新模型；對話太長時自動壓縮，門檻可以自己調。
- 輸入框沒字時會用灰字猜你的下一句，按 Tab 採用。

**版面與視窗**
- 側欄可以分組、建子組、拖曳排序、封存一週沒用的對話。
- 一個 Window 裡可以把格子左右或上下切開，比例自己拖，⌘ Q 重開後照原樣。
- 鍵盤操作沿用 tmux 的習慣（Ctrl + A 前綴），也有 Mac 的快捷鍵：⌘ W 關掉目前那格，⌘ ⇧ T 把剛關掉的格子或整個 Window 照原樣找回來。

**瀏覽器格子與掛件**
- 內建瀏覽器格子（WebKit），可以登入網站、上傳檔案，⌘ + / ⌘ − 縮放，縮放比例會照網站記住。
- 「掛件框」：在側欄用紫框把幾段聊天室框在一起，框底下掛 Gemini、NotebookLM 或任何網頁。按 ⌘ ⇧ B，掛件會從右邊彈出來，再按一次收起；收起只是不顯示，網頁不用重新載入。
- AI 可以用 `codenv-browser` 指令讀瀏覽器格子的文字或截圖，但只能讀、不能操作。

**多個 AI 一起工作**
- 協作看板：開目標、拆步驟、指定誰負責。Claude 開的目標要你按「同意」才會開始做，最後一步「使用者驗收」只有你本人能勾。
- 兩個 Claude 聊天室可以互傳訊息分工，例如一個負責寫程式，另一個負責審查和出版。
- 排程：在指定的時間自動送一則訊息給某段對話。
- 右側欄顯示各家模型的用量剩多少、每格正在用哪個模型、對話已經多長。

**程式碼學習區**
- 內建 Monaco 編輯器，可以寫 C／C++／Python 的練習程式並直接執行，不用另外開資料夾。

**其他**
- 更新提醒：有新版時在側欄提醒你，可以看更新說明、下載或略過這版。
- 回報問題：可以寄 email，或到 GitHub 開 issue，版本資訊會先幫你填好。
- 斷網時不會亂叫需要登入的工具，避免一直跳出登入頁。

## 用到、參考的開源專案

- [Claude Code](https://github.com/anthropics/claude-code)：主角，每個聊天室都是一段 Claude Code 對話。
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)：終端機格子（MIT，放在 `vendor/`，修改處記在 `vendor/PATCHES.md`）。
- [marked](https://github.com/markedjs/marked)、[highlight.js](https://github.com/highlightjs/highlight.js)：聊天畫面的 Markdown 和程式碼上色。
- [Monaco Editor](https://github.com/microsoft/monaco-editor)：程式碼學習區的編輯器。
- [Codex CLI](https://github.com/openai/codex)、[GitHub Copilot CLI](https://github.com/github/copilot-cli)：可選的其他模型。
- [mlx-lm](https://github.com/ml-explore/mlx-lm)、[mlx-vlm](https://github.com/Blaizzy/mlx-vlm)：在 Mac 上跑本機模型。
- [tmux](https://github.com/tmux/tmux)：快捷鍵和「Session → Window → 格子」的結構，都是照 tmux 的習慣做的。
- [codenv_old](https://github.com/olilllioli287/codenv_old)：這個 App 的前身，用 vim 加 tmux 拼成的工作環境。
- [claude-code-image-shelf](https://github.com/olilllioli287/claude-code-image-shelf)：圖片標註工具，聊天室裡的圖片編輯用的就是它。

## 接下來想做的

- **目前以 Claude Code 為主**：先把 Claude 的體驗做穩，其他模型照舊是可選的。
- **程式碼學習區**：做得更完整，例如照章節練習、讀本搭配 AI 家教一起學、更好的執行與除錯畫面。
- **新功能**：持續加入日常用得到的小功能，也歡迎在 issue 裡提。
- **掛件框的後續**：掛件現在可以掛 Gemini、NotebookLM 和網頁，之後想讓掛件跟它掛著的聊天室有更多互動，並評估做 Chromium 版的瀏覽器格子。

## 需求

- macOS 14 以上、Apple Silicon
- 已安裝並登入 [Claude Code](https://claude.com/claude-code)（在終端機打 `claude` 能用）
- 可選：Codex CLI、GitHub Copilot CLI、本機 MLX 模型

## 安裝

1. 到 [Releases](https://github.com/olilllioli287/codenv-public/releases/latest) 下載 `codenv-<版本>.dmg`，把 codenv 拖進「應用程式」。
2. App 用的是臨時（ad-hoc）簽章，沒有 Apple 開發者簽名。第一次打開時，要對 codenv 按右鍵 →「打開」→「打開」。還是打不開的話，到「系統設定 → 隱私權與安全性」按「強制打開」。
3. 因為是臨時簽章，**每次換新版，macOS 都會把它當成不同的 App**：你給過的權限（例如完整磁碟取用權限）更新後可能要重新給一次。

## 更新提醒

codenv 開啟 30 秒後會檢查一次 GitHub Releases 有沒有新版，之後每 24 小時檢查一次，也可以在設定裡按「檢查更新」。它只對 `api.github.com` 送出一個普通的請求，不帶任何使用者資料，也不帶識別碼。這個功能可以在設定的「自動檢查更新」關掉。它不會自己替換 App：有新版時只顯示更新說明，按下按鈕才開啟下載頁。

## 回報問題

設定頁和選單裡都有「回報問題…」，可以寄 email 到 codenvstudio@gmail.com，或到 GitHub 開 issue。錯誤紀錄預設不附；要附的話自己勾選，附之前會先把路徑裡的使用者名稱換掉。

## agy（Google Antigravity CLI）：預設關閉

Gemini 聊天室、灰字下一句建議、用量查詢、看板自動做事，都是由 codenv 去呼叫 Google 的 `agy`。Google 官方 FAQ（<https://antigravity.google/docs/faq/>）寫著：

> Antigravity CLI headless mode (`agy -p`) is intended for direct scripting and CI workflows. Wrapping `agy` inside third-party coding agents or applications, or automating account rotation, is not supported under consumer plans.

> Using third-party software, tools, or services to access Antigravity is a violation of our Terms of Service … Such actions can result in suspension or termination of your account.

所以這個功能**預設關閉**。要打開（設定 → 對話 → agy）會先跳出上面這段警告。打開之後，你的 Google 帳號可能會被停權，風險由你自己承擔；codenv 沒有做任何隱藏自己的處理。

## 從原始碼編譯

```bash
git clone https://github.com/olilllioli287/codenv-public.git
cd codenv-public
./build.sh                                   # 編譯、臨時簽章、裝到 ~/Applications/codenv.app
CODENV_SIGN_IDENTITY="我的憑證" ./build.sh   # 用自己的憑證簽章（重新編譯後權限不會掉）
```

## 可選的輔助指令

`scripts/codenv-todo`（多個 AI 共用的協作看板）和 `scripts/codenv-browser`（讀瀏覽器格子的網頁內容）這兩個小指令，要用的話複製到 `PATH` 裡的資料夾就好。

## 授權

MIT（見 `LICENSE`）。`vendor/` 和 `Resources/` 裡的第三方程式各自保留原本的授權。
