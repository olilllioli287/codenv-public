#!/bin/bash
# 考卷 C 類：要開原生 codenv 的案例。用法：native.sh <案例 ID> <repo 根目錄>
# 需要 EXAM_APP=<測試用 codenv.app 路徑>（例：APP=/tmp/x/codenv-test.app ./build.sh --no-open --no-register 做出來的）
# 一律 open -g（不搶前景）＋暫存 --state-dir（不碰正式資料）；跑完按 pid 關掉自己開的測試版
set -u
ID="$1"
APP="${EXAM_APP:?要設 EXAM_APP=<測試用 codenv.app>}"
BIN="$APP/Contents/MacOS/Workbench"
[ -x "$BIN" ] || { echo "找不到 $BIN"; exit 1; }
T=$(mktemp -d /tmp/codenv-exam-native.XXXXXX)
trap 'stop; rm -rf "$T"' EXIT
stop() { for p in $(pids "$BIN"); do ps -o command= -p "$p" | grep -q -- "$T" && kill "$p"; done; sleep 1; }
launch() { open -g -n "$APP" --args --state-dir "$1" --background -NSAppSleepDisabled YES "${@:2}"; }
convs() { python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['conversations']))" "$1" 2>/dev/null || echo "讀不懂"; }
fail=0
# 找程序：不用 pgrep -f（系統上任何一個程序的參數有非 ASCII 字，例如 agy 的中文題目，pgrep 就整個報錯回空，
# 測試版關不掉、後面全部連鎖失敗）。用 ps 整份列出、固定字串比對；排除這個比對指令自己
pids() { LC_ALL=C ps -ax -o pid=,command= | LC_ALL=C awk -v pat="$1" 'index($0, pat) && !index($0, "awk -v pat") {print $1}'; }
check() { if [ "$2" = "$3" ]; then echo "  斷言通過：$1"; else echo "  斷言失敗：$1（期望 $3，實際 $2）"; fail=1; fi; }

case "$ID" in
C13)
    D="$T/state"; mkdir -p "$D" "$T/proj"
    # 1. 建一段對話，再開一次讓它備份
    launch "$D" --new-conv-at "1:$T/proj"; sleep 6; stop
    launch "$D" --new-conv-at "1:$T/proj"; sleep 6; stop
    check "有備份" "$([ -f "$D/state.json.bak" ] && echo 有 || echo 無)" "有"
    n=$(convs "$D/state.json.bak")
    # 2. 空檔 → 用備份還原並寫回
    : > "$D/state.json"; launch "$D"; sleep 6; stop
    check "空檔用備份還原" "$(convs "$D/state.json")" "$n"
    # 3. 壞檔 → 用備份還原，壞的另存「讀不到」
    printf '{"壞掉' > "$D/state.json"; launch "$D"; sleep 6; stop
    check "壞檔用備份還原" "$(convs "$D/state.json")" "$n"
    check "壞檔另存一份" "$(ls "$D" | grep -c '讀不到')" "1"
    # 3b. 整個檔被刪掉、有備份 → 用備份還原（不是開成空工作台）
    rm -f "${D:?}/state.json"; launch "$D"; sleep 6; stop
    check "檔案不見用備份還原" "$(convs "$D/state.json")" "$n"
    # 3c. 子程序活得比 codenv 久也不能卡住鎖：假 claude 睡 60 秒，強制結束 codenv 後要能馬上再開
    printf '#!/bin/sh\nsleep 60\n' > "$T/fake-claude"; chmod +x "$T/fake-claude"
    launch "$D" --chat-claude "$T/fake-claude" --chat-send "3:hi"; sleep 7
    for p in $(pids "$BIN"); do ps -o command= -p "$p" | grep -q -- "$T" && kill -9 "$p"; done; sleep 1
    check "假 claude 還活著" "$([ -n "$(pids "$T/fake-claude")" ] && echo 是 || echo 否)" "是"
    launch "$D"; sleep 6
    check "子程序還在時能再開" "$(for p in $(pids "$BIN"); do ps -o command= -p "$p"; done | grep -c -- "$T")" "1"
    stop; for p in $(pids "$T/fake-claude"); do kill "$p"; done
    # 4. 壞檔、沒有備份 → 壞的那份要留著（另存），不能只剩空工作台
    rm -f "$D/state.json.bak" "$D"/state.json.讀不到-*; printf '{"壞掉2' > "$D/state.json"; launch "$D"; sleep 6; stop
    check "沒備份時壞檔仍保留一份" "$(grep -l '壞掉2' "$D"/state.json.讀不到-* 2>/dev/null | wc -l | tr -d ' ')" "1"
    # 5. 同資料夾第二個 codenv 不能開
    launch "$D"; sleep 4; launch "$D"; sleep 6
    check "同資料夾只開一個" "$(for p in $(pids "$BIN"); do ps -o command= -p "$p"; done | grep -c -- "$T")" "1"
    stop
    ;;
C14)
    D="$T/state"; mkdir -p "$D" "$T/proj"
    # 規格 C14：CodeLab 開檔 A、改開檔 B 之後才收到網頁送來 path=A 的 save 訊息，B 的 bytes 不能變、A 也不能被寫成 B 的內容
    printf '// initial A\nint a = 100;\n' > "$T/proj/a.cpp"
    printf '// initial B\nint b = 200;\n' > "$T/proj/b.cpp"
    launch "$D" --new-conv-at "1:$T/proj" --codelab-delayed-save-probe "3:$T/proj/a.cpp:$T/proj/b.cpp:$T/out.txt"
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "probe 正常完成" "$([ -f "$T/out.txt" ] && echo 有 || echo 無)" "有"
    check "B 的 bytes 未被舊存檔修改" "$([ -f "$T/out.txt" ] && grep -c 'b_intact=true' "$T/out.txt" || true)" "1"
    check "A 的 bytes 未被竄改" "$([ -f "$T/out.txt" ] && grep -c 'a_intact=true' "$T/out.txt" || true)" "1"
    check "A 內容未被寫成 B" "$([ -f "$T/out.txt" ] && grep -c 'a_not_b=true' "$T/out.txt" || true)" "1"
    check "磁碟上 B 內容完全吻合" "$([ "$([ -f "$T/proj/b.cpp" ] && cat "$T/proj/b.cpp")" = "$(printf '// initial B\nint b = 200;\n')" ] && echo 是 || echo 否)" "是"
    check "磁碟上 A 內容完全吻合" "$([ "$([ -f "$T/proj/a.cpp" ] && cat "$T/proj/a.cpp")" = "$(printf '// initial A\nint a = 100;\n')" ] && echo 是 || echo 否)" "是"
    ;;
C15)
    D="$T/state"; mkdir -p "$D" "$T/proj"
    # 規格 C15：焦點在程式碼編輯器時 Tab、/、⌃C、⌃Enter 留在編輯器；焦點在聊天輸入框時照聊天行為
    printf '// c15 test\nint main() { return 0; }\n' > "$T/proj/main.cpp"
    launch "$D" --new-conv-at "1:$T/proj" --codelab-focus-keys-probe "3:$T/out.txt"
    # 8 個按鍵步驟各約 0.8 秒＋編輯器載入，實測約 12 秒；等到輸出檔出現為止（最多 40 秒）
    for i in $(seq 1 40); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "probe 正常完成" "$([ -f "$T/out.txt" ] && echo 有 || echo 無)" "有"
    check "編輯器焦點：Tab 留在編輯器" "$([ -f "$T/out.txt" ] && grep -c 'editor_tab=true' "$T/out.txt" || true)" "1"
    check "編輯器焦點：/ 留在編輯器" "$([ -f "$T/out.txt" ] && grep -c 'editor_slash=true' "$T/out.txt" || true)" "1"
    check "編輯器焦點：⌃C 留在編輯器" "$([ -f "$T/out.txt" ] && grep -c 'editor_ctrl_c=true' "$T/out.txt" || true)" "1"
    check "編輯器焦點：⌃Enter 留在編輯器" "$([ -f "$T/out.txt" ] && grep -c 'editor_ctrl_enter=true' "$T/out.txt" || true)" "1"
    check "聊天焦點：Tab 採用建議" "$([ -f "$T/out.txt" ] && grep -c 'chat_tab=true' "$T/out.txt" || true)" "1"
    check "聊天焦點：/ 跳回輸入框" "$([ -f "$T/out.txt" ] && grep -c 'chat_slash=true' "$T/out.txt" || true)" "1"
    check "聊天焦點：⌃C 觸發聊天中斷" "$([ -f "$T/out.txt" ] && grep -c 'chat_ctrl_c=true' "$T/out.txt" || true)" "1"
    check "聊天焦點：⌃Enter 觸發馬上送出" "$([ -f "$T/out.txt" ] && grep -c 'chat_ctrl_enter=true' "$T/out.txt" || true)" "1"
    ;;
C16)
    # 隱藏的聊天格網頁卸載後，排程／交接這類程式代送要把網頁建回來，切回去時這則才看得到（991cb63）
    D="$T/state"; mkdir -p "$D" "$T/a" "$T/b"
    printf '#!/bin/sh\nsleep 60\n' > "$T/fake-claude"; chmod +x "$T/fake-claude"
    # A 先放草稿才不會被當空草稿收掉；切到 B 後清空 A，讓它 3 秒後卸載
    launch "$D" --chat-claude "$T/fake-claude" --web-unload-seconds 3 \
      --new-conv-at "1:$T/a" --set-input "2:A 的草稿" --new-conv-at "3:$T/b" --bg-send "5:$T/a:<clear>" \
      --web-probe "12:$T/a:$T/p1.txt" --bg-send "13:$T/a:背景代送考題C16" --web-probe "19:$T/a:$T/p2.txt"
    for i in $(seq 1 30); do [ -s "$T/p2.txt" ] && break; sleep 1; done
    stop; for p in $(pids "$T/fake-claude"); do kill "$p"; done
    check "代送前網頁已卸載" "$(head -1 "$T/p1.txt" 2>/dev/null)" "hasWeb=false inWindow=false"
    check "代送後網頁建回" "$(head -1 "$T/p2.txt" 2>/dev/null)" "hasWeb=true inWindow=false"
    check "畫面上有代送的那則" "$(grep -c '背景代送考題C16' "$T/p2.txt" 2>/dev/null)" "1"
    ;;
C17)
    # 網頁卸載後代送訊息；歷史已含完整回答時，重播串流不能讓文字出現兩次。
    # 第 14～36 秒每秒讀一次畫面（串流與結束時間會隨機器忙碌飄移；這輪結束後不在版面上的格子會被收掉），取最多的那次：
    # 至少一次看到＝真的畫到了；任何一次 2 次以上＝重複
    D="$T/state"; H="$T/claude"; mkdir -p "$D" "$H" "$T/a" "$T/b"
    FAKE="$(cd "$2" && pwd)/scripts/exam/fake-claude-stream.py"   # 轉絕對路徑：App 由 open 啟動，工作目錄不在 repo
    probes=(); for s in $(seq 14 36); do probes+=(--web-probe "$s:$T/a:$T/q$s.txt"); done
    launch "$D" --claude-home "$H" --chat-claude "$FAKE" --web-unload-seconds 3 \
      --new-conv-at "1:$T/a" --set-input "2:A 的草稿" --new-conv-at "3:$T/b" --bg-send "5:$T/a:<clear>" \
      --web-probe "9:$T/a:$T/p1.txt" --bg-send "10:$T/a:背景代送考題C17" "${probes[@]}"
    for i in $(seq 1 60); do [ -s "$T/q36.txt" ] && break; sleep 1; done
    stop; for p in $(pids "$FAKE"); do kill "$p"; done
    max=0; for f in "$T"/q*.txt; do n=$(grep -o '串流考題C17-唯一字串' "$f" 2>/dev/null | wc -l | tr -d ' '); [ "$n" -gt "$max" ] && max=$n; done
    check "代送前已卸載" "$(head -1 "$T/p1.txt" 2>/dev/null)" "hasWeb=false inWindow=false"
    check "畫面上唯一字串最多出現 1 次（且有出現）" "$max" "1"
    if [ "$max" != "1" ]; then for s in 14 20 26 32 36; do echo "    第 $s 秒：$(head -2 "$T/q$s.txt" 2>/dev/null | tr '\n' ' ')"; done; fi
    ;;
C18)
    # 程序被主動關掉（換模型重開、停 agy、關格子）時，還沒確認的訊息不能一直掛著：要放回輸入框、寄件匣保留（ChatSession.terminate）
    D="$T/state"; mkdir -p "$D" "$T/proj"
    printf '#!/bin/sh\nsleep 60\n' > "$T/fake-claude"; chmod +x "$T/fake-claude"
    launch "$D" --chat-claude "$T/fake-claude" --new-conv-at "1:$T/proj" --chat-send "3:考題C18沒確認的訊息" \
      --outbox-probe "5:dump:$T/d1.json" --chat-respawn "6" --outbox-probe "8:dump:$T/d2.json"
    for i in $(seq 1 30); do [ -s "$T/d2.json" ] && break; sleep 1; done
    stop; for p in $(pids "$T/fake-claude"); do kill "$p"; done
    j() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print($2)" "$1" 2>/dev/null || echo 讀不到; }
    check "關掉前還在等確認" "$(j "$T/d1.json" "d['hasUnackedInput']")" "True"
    check "關掉後不再掛著" "$(j "$T/d2.json" "d['hasUnackedInput']")" "False"
    check "寄件匣保留那則" "$(j "$T/d2.json" "len(d['outboxIDs'])")" "1"
    check "原文放回輸入框" "$(j "$T/d2.json" "d['input']")" "考題C18沒確認的訊息"
    ;;
C19)
    # 程序不讀 stdin（剛啟動、卡住）時送超過 pipe 緩衝的大訊息，主執行緒不能被卡住（寫入放背景佇列）
    D="$T/state"; mkdir -p "$D" "$T/proj"
    printf '#!/bin/sh\nsleep 30\n' > "$T/fake-claude"; chmod +x "$T/fake-claude"
    big=$(python3 -c "print('大'*60000)")
    t0=$(date +%s)
    launch "$D" --chat-claude "$T/fake-claude" --new-conv-at "1:$T/proj" --chat-send "3:$big" --outbox-probe "6:dump:$T/d1.json"
    for i in $(seq 1 40); do [ -s "$T/d1.json" ] && break; sleep 1; done
    el=$(( $(date +%s) - t0 ))
    stop; for p in $(pids "$T/fake-claude"); do kill "$p"; done
    check "排在第 6 秒的動作 12 秒內就跑（沒被大寫入卡住）" "$([ "$el" -le 12 ] && echo 是 || echo "否（$el 秒）")" "是"
    check "大訊息有登記在寄件匣" "$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['outboxIDs']))" "$T/d1.json" 2>/dev/null)" "1"
    ;;
C20)
    # 每個聊天室的 MCP 模式（McpMode）：lite／none 用 --strict-mcp-config 關掉外掛、claude.ai、使用者設定的 MCP，也不帶 --chrome；full／沒設照舊
    for M in "" lite none full; do
        D="$T/state-$M"; H="$T/claude-$M"; mkdir -p "$D" "$H" "$T/proj"
        printf '#!/bin/sh\necho "$@" >> %s\nsleep 20\n' "$T/argv-$M.log" > "$T/fake-claude-$M"; chmod +x "$T/fake-claude-$M"
        launch "$D" --claude-home "$H" --chat-claude "$T/fake-claude-$M" --new-conv-at "1:$T/proj"; sleep 6; stop
        if [ -n "$M" ]; then python3 -c "
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for c in d['conversations']: c['mcp']=sys.argv[2]
json.dump(d,open(p,'w'),ensure_ascii=False)" "$D/state.json" "$M"; fi
        launch "$D" --claude-home "$H" --chat-claude "$T/fake-claude-$M" --chat-send "3:hi"; sleep 8; stop
        for p in $(pids "$T/fake-claude-$M"); do kill "$p"; done
    done
    has() { grep -q -- "$2" "$T/argv-$1.log" 2>/dev/null && echo 有 || echo 無; }
    check "沒設：帶 --chrome" "$(has "" --chrome)" "有"
    check "沒設：沒有 --strict-mcp-config" "$(has "" --strict-mcp-config)" "無"
    check "lite：有 --strict-mcp-config" "$(has lite --strict-mcp-config)" "有"
    check "lite：沒有 --chrome" "$(has lite --chrome)" "無"
    # 設定（可能含 env 金鑰）寫在 state 資料夾裡權限 0600 的檔案，命令列只傳路徑，不能出現在 ps（00.06.00）
    LF="$T/state-lite/mcp/mcp-lite.json"
    check "lite：只留 deja（不含 rea、chrome）" "$([ -f "$LF" ] && grep -q '"deja"' "$LF" && ! grep -q '"rea"\|chrome-devtools' "$LF" && echo 是 || echo 否)" "是"
    check "lite：設定檔權限 0600" "$([ -f "$LF" ] && stat -f %Lp "$LF" || echo 無檔)" "600"
    check "lite：命令列只有路徑、沒有設定內容" "$(grep -q -- "--mcp-config $LF" "$T/argv-lite.log" && ! grep -q '"deja"' "$T/argv-lite.log" && echo 是 || echo 否)" "是"
    check "none：空的 mcpServers" "$(has none '{"mcpServers":{}}')" "有"
    check "none：沒有 --chrome" "$(has none --chrome)" "無"
    check "full：跟沒設一樣（有 --chrome、無 strict）" "$(has full --chrome)$(has full --strict-mcp-config)" "有無"
    ;;
*) echo "沒有這個原生案例：$ID"; exit 1 ;;
esac
exit $fail
