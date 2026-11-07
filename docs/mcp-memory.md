# 聊天室記憶體：MCP 精簡、閒置收程序、MCP 能不能共用（2026-11-07）

## 量測（11 個 claude 程序，只讀 ps）
- claude 本體平均約 307 MB；MCP 子程序平均約 323 MB／聊天室：
  chrome-devtools 約 262 MB（兩套，每套 npm exec 45 + 包裝 46 + node 39）、rea 約 40 MB、deja 約 21 MB。
- Claude Code 2.1.318 實測（init 事件的 mcp_servers／tools）：
  - 不加參數：9 個 MCP 伺服器、210 個工具（外掛 supabase／vercel／chrome-devtools／pixel-plugin、使用者設定的 rea／chrome-real／deja、claude.ai Claude Docs／Google Drive）。
  - `--strict-mcp-config`（不給 --mcp-config）：0 個伺服器、28 個工具。外掛和 claude.ai 連接器也一併關掉，不用動 settings.json。
  - `--strict-mcp-config --mcp-config '{"mcpServers":{"deja":…}}'`：只剩 deja（32 個工具）。
  - `--chrome`（claude-in-chrome）擋不掉，strict 之後仍會連上，所以精簡／不載入時 codenv 不帶 --chrome。

## 做法
- 每個聊天室一個 `mcp` 欄位：full（預設，沒設＝full）、lite（只留 deja）、none。啟動 claude 時由 codenv 加參數，不碰 ~/.claude/settings.json 與 ~/.claude.json（只讀 deja 的設定原樣帶入）。
- `codenv-todo new` 預設 lite，`--mcp full|lite|none` 可改；右鍵（側欄、右欄）「MCP（下次啟動生效）」可切。總指揮聊天室與手開的聊天室維持 full。
- 閒置收程序：不在畫面上的聊天室「待命」超過 15 分鐘就結束 claude（之後 --resume 接回）。範圍＝總指揮模式下背景 Session 的聊天格（原本 30 分鐘，改 15）＋ wake／new 喚醒但沒擺進版面的聊天室（原本永遠不收）。安全檢查沿用 canRelease。

## MCP 能不能共用
stdio 的 MCP 本來就是「每個 claude 程序自己 spawn 一份」，沒有共用的機制。要共用，伺服器得以 HTTP（streamable HTTP／SSE）常駐一份，各 claude 用 `{"type":"http","url":…}` 連。
本機三個 MCP 的現況：
- deja：`deja mcp` 只有 stdio（help 沒有 http／port 選項），且只有 21 MB，共用的收益很小。
- rea：`rea mcp` 只有 stdio（子命令只有 add／doctor），40 MB，收益小；它開的 Ghidra 專案、二進位 session 有狀態，多聊天室共用會互相覆蓋。
- chrome-devtools-mcp 1.9.0：help 沒有 http／transport 選項，只能 stdio。它有「目前選的分頁」狀態；有 `--pageIdRouting`（預設開，工具要帶 pageId）是為了多個 agent 同時用，但選頁、快照編號仍是每個連線各自的，多聊天室同時操作同一個 Chrome 會互相搶；比較穩的是各聊天室只在需要時開。
要共用只能在前面加一層 stdio→HTTP 轉接（例如 supergateway、mcp-proxy 之類的第三方工具），再常駐一個 LaunchAgent。代價：多一個常駐程序要維護、轉接層本身多一個故障點、有狀態的 MCP 會互相干擾、第三方套件要審。
建議：不做共用。收益最大的是「不需要的聊天室不載」（已做 lite／none），其次兩件不需要常駐服務的設定（只是建議，未動）：
1. chrome-devtools 現在有兩套（外掛 chrome-devtools-mcp 與 ~/.claude.json 的 chrome-real --autoConnect），多半重複；停用其中一套，每個載入完整 MCP 的聊天室省約 130 MB。
2. 把 `npx chrome-devtools-mcp@1.9.0` 改成直接用 node 跑安裝好的檔案，可省掉 npm exec 與包裝兩層（每套約 90 MB，估計值，沒實測）。
