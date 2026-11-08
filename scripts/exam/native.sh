#!/bin/bash
# 考卷 C 類：要開原生 codenv 的案例。用法：native.sh <案例 ID> <repo 根目錄>
# 需要 EXAM_APP=<測試用 codenv.app 路徑>（例：APP=/tmp/x/codenv-test.app ./build.sh --no-open --no-register 做出來的）
# 一律 open -g（不搶前景）＋暫存 --state-dir（不碰正式資料）；跑完按 pid 關掉自己開的測試版
set -u
ID="$1"
ROOTDIR="${2:-$(cd "$(dirname "$0")/../.." && pwd)}"
APP="${EXAM_APP:?要設 EXAM_APP=<測試用 codenv.app>}"
BIN="$APP/Contents/MacOS/Workbench"
[ -x "$BIN" ] || { echo "找不到 $BIN"; exit 1; }
T=$(mktemp -d /tmp/codenv-exam-native.XXXXXX)
trap 'stop; rm -rf "$T"' EXIT
stop() { for p in $(pids "$BIN"); do ps -o command= -p "$p" | grep -q -- "$T" && kill "$p"; done; sleep 1; }
launch() { open -g -n "$APP" --args --state-dir "$1" --background -NSAppSleepDisabled YES -ApplePersistenceIgnoreState YES "${@:2}"; }
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
C21)
    # codenv-todo area add 遇到別的總指揮底下同名同父的組：必須失敗、不能把那組刪掉；removeGroup 要清掉總指揮涵蓋清單的失效 id
    D="$T/state"; mkdir -p "$D"
    launch "$D" --area-add-probe "$T/out.txt"
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "probe 正常完成" "$([ -f "$T/out.txt" ] && echo 有 || echo 無)" "有"
    check "同名同父：建區失敗" "$([ -f "$T/out.txt" ] && grep -c '^ok=false' "$T/out.txt" || true)" "1"
    check "別人的同名組沒被刪" "$([ -f "$T/out.txt" ] && grep -c 'zStillThere=true' "$T/out.txt" || true)" "1"
    check "removeGroup 清掉涵蓋清單的失效 id" "$([ -f "$T/out.txt" ] && grep -c 'staleIdCleared=true' "$T/out.txt" || true)" "1"
    ;;
C22)
    # send --wait --timeout 20：伺服器端不能固定 15 秒就回「再試一次」（訊息其實已送出，呼叫端會重送）；要等到 timeout 以上，並提醒不要重送
    D="$T/state"; mkdir -p "$D"
    launch "$D" --hang-send; sleep 6
    OUT=$(python3 "$ROOTDIR/scripts/exam/send-wait-probe.py" "$D/browser" 1 20 2>&1)
    SECS=$(echo "$OUT" | sed -n 's/^\([0-9]*\) 秒.*/\1/p')
    stop
    check "--wait 20 秒沒有在 15 秒就回" "$([ -n "$SECS" ] && [ "$SECS" -ge 20 ] && echo 是 || echo "否（$OUT）")" "是"
    check "逾時訊息叫人不要重送" "$(echo "$OUT" | grep -c '不要重送')" "1"
    ;;
C23)
    # Usage.friendlyDate：沒有年份的重置時間跨年要選對年（12 月底讀到 Jan 1 → 明年；1 月初讀到 Dec 31 → 去年）
    D="$T/state"; mkdir -p "$D"
    launch "$D" --usage-date-probe "$T/out.txt"
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "probe 正常完成" "$([ -f "$T/out.txt" ] && echo 有 || echo 無)" "有"
    check "12 月底讀到 Jan 1 算明年" "$([ -f "$T/out.txt" ] && grep -c 'dec_to_jan=2027-1-1' "$T/out.txt" || true)" "1"
    check "1 月初讀到 Dec 31 算去年" "$([ -f "$T/out.txt" ] && grep -c 'jan_to_dec=2026-12-31' "$T/out.txt" || true)" "1"
    check "同一年照舊" "$([ -f "$T/out.txt" ] && grep -c 'same_year=2026-11-9' "$T/out.txt" || true)" "1"
    ;;
C24)
    # 看板 collab.json 有一個壞目標：只跳過那一筆，其他目標照常讀到，原檔不動
    D="$T/state"; mkdir -p "$D"
    launch "$D" --board-bad-probe "$T/out.txt"
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "probe 正常完成" "$([ -f "$T/out.txt" ] && echo 有 || echo 無)" "有"
    check "好的兩個目標還在" "$([ -f "$T/out.txt" ] && grep -c '^goals=g1,g3$' "$T/out.txt" || true)" "1"
    check "原檔沒被改" "$([ -f "$T/out.txt" ] && grep -c 'fileIntact=true' "$T/out.txt" || true)" "1"
    ;;
C25)
    # 開 Big5 檔不改、換開別的檔：Big5 檔的位元組不能被悄悄存成 UTF-8
    D="$T/state"; mkdir -p "$D" "$T/proj"
    python3 -c "open('$T/proj/a.cpp','wb').write('// 中文註解\nint a = 1;\n'.encode('big5'))"
    printf '// other\nint b = 2;\n' > "$T/proj/b.cpp"
    launch "$D" --new-conv-at "1:$T/proj" --codelab-big5-probe "3:$T/proj/a.cpp:$T/proj/b.cpp:$T/out.txt"
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "probe 正常完成" "$([ -f "$T/out.txt" ] && echo 有 || echo 無)" "有"
    check "Big5 檔沒被改寫" "$([ -f "$T/out.txt" ] && grep -c 'big5_intact=true' "$T/out.txt" || true)" "1"
    check "有換到別的檔" "$([ -f "$T/out.txt" ] && grep -c 'current_file=.*b.cpp' "$T/out.txt" || true)" "1"
    ;;
C26)
    # 聊天網頁的 WebContent 程序被殺掉：要自動重載、ready 重新成立（舊版畫面變白、ready 一直是 true）
    D="$T/state"; mkdir -p "$D" "$T/proj"
    launch "$D" --new-conv-at "1:$T/proj" --web-crash-probe "5:$T/out.txt"
    for i in $(seq 1 40); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "probe 正常完成" "$([ -f "$T/out.txt" ] && echo 有 || echo 無)" "有"
    check "崩潰前 ready 成立過 1 次" "$([ -f "$T/out.txt" ] && grep -c 'ready_count_before=1' "$T/out.txt" || true)" "1"
    check "崩潰後重載、ready 又成立（累計 2 次）" "$([ -f "$T/out.txt" ] && grep -c 'ready_count_after=2' "$T/out.txt" || true)" "1"
    ;;
C27)
    # 看板開著、目標很多時按 F4（收右欄）：1 秒內收完，主執行緒最長停頓 < 100ms（修前：右欄動畫先被桌寵格的寬度擠窄再彈回，看板整份重排兩次，實測 150～180ms）
    D="$T/state"; mkdir -p "$D"
    python3 - "$D/collab.json" <<'PY'
import json, sys
goals = []
for g in range(120):
    goals.append({"id": "g%03d" % g, "title": "考題目標 %d：把一段很長的說明寫在標題裡，讓卡片會換好幾行，重排時才吃得出差別" % g, "status": "active", "by": "exam",
                  "at": "2026-11-01T00:00:00.000Z", "done": "完成條件 %d：這裡也放一段會換行的中文文字，驗收看板在資料很多時的版面成本" % g,
                  "steps": [{"id": "s%03d%d" % (g, k), "state": "todo", "at": "2026-11-01T00:00:00.000Z", "text": "步驟 %d-%d：一段足夠長、會換行的步驟文字，用來撐高每張卡片" % (g, k)} for k in range(6)]})
json.dump({"autoApprove": True, "findings": [], "goals": goals, "items": []}, open(sys.argv[1], "w"), ensure_ascii=False)
PY
    launch "$D" --pref sidebarMode=commander --pref petSlotOn=0 --right-stall-probe "3:看板:$T/out.txt"
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done
    stop
    ms=$(sed -n 's/.*maxStallMs=\([0-9]*\).*/\1/p' "$T/out.txt" 2>/dev/null)
    check "1 秒內收完" "$(sed -n 's/.*collapsed1s=\([a-z]*\).*/\1/p' "$T/out.txt" 2>/dev/null)" "yes"
    check "最長停頓 < 100ms（實測 ${ms:-無資料}ms）" "$([ -n "$ms" ] && [ "$ms" -lt 100 ] && echo 是 || echo 否)" "是"
    ;;
C29)
    # 沙盒讀鑰匙圈的 security 卡住（鎖住、等授權視窗）：keychain() 要在逾時後回 nil，不能把畫面卡死
    D="$T/state"; mkdir -p "$D"
    launch "$D" --keychain-timeout-probe "$T/out.txt"
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "probe 正常完成" "$([ -f "$T/out.txt" ] && echo 有 || echo 無)" "有"
    check "卡住的 security 回 nil" "$([ -f "$T/out.txt" ] && grep -c 'result_nil=true' "$T/out.txt" || true)" "1"
    check "幾秒內就回（沒等滿 30 秒）" "$([ -f "$T/out.txt" ] && grep -c 'fast=true' "$T/out.txt" || true)" "1"
    ;;
C30)
    # 更新檢查的 git ls-remote 遇到不回應的伺服器：要逾時失敗，不能一直卡著（busy 永遠 true）
    D="$T/state"; mkdir -p "$D"
    PORT=$((20000 + RANDOM % 20000))
    python3 "$ROOTDIR/scripts/exam/hang-server.py" "$PORT" & HP=$!
    sleep 1
    launch "$D" --update-check-probe "http://127.0.0.1:$PORT/x.git|$ROOTDIR|$T/out.txt"
    for i in $(seq 1 40); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop; kill "$HP" 2>/dev/null
    check "probe 正常完成（沒卡住）" "$([ -f "$T/out.txt" ] && echo 有 || echo 無)" "有"
    check "回報連線逾時" "$([ -f "$T/out.txt" ] && grep -c '連線逾時' "$T/out.txt" || true)" "1"
    ;;
C32)
    # 很長的請求（3 萬個中文字＝約 90 KB）：伺服器要收得完。舊版只讀 64 KB，JSON 被截斷，codenv-todo send 長訊息必失敗
    D="$T/state"; mkdir -p "$D"
    launch "$D"; sleep 6
    OUT=$(python3 "$ROOTDIR/scripts/exam/big-request-probe.py" "$D/browser" 30000 2>&1)
    stop
    check "長請求被正常處理" "$OUT" "ok=True "
    ;;
C33)
    # 檔名以 - 開頭（-Wall.cpp）的 C++ 檔做檢查：不能被 g++ 當成選項（舊版檢查失敗）
    D="$T/state"; mkdir -p "$D"
    launch "$D" --runner-dash-probe "$T/out.txt"
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "probe 正常完成" "$([ -f "$T/out.txt" ] && echo 有 || echo 無)" "有"
    check "-Wall.cpp 檢查通過" "$([ -f "$T/out.txt" ] && grep -c 'status_ok=true' "$T/out.txt" || true)" "1"
    check "執行指令用 ./ 開頭的檔名" "$([ -f "$T/out.txt" ] && grep -c 'cmd_has_dotslash=true' "$T/out.txt" || true)" "1"
    check "有錯誤的 -bad.cpp 檢查失敗" "$([ -f "$T/out.txt" ] && grep -c 'bad_failed=true' "$T/out.txt" || true)" "1"
    check "  而且診斷沒被濾掉（有行號標記）" "$([ -f "$T/out.txt" ] && grep -c 'bad_diag_count=[1-9]' "$T/out.txt" || true)" "1"
    ;;
C34)
    # 排程防重送標記要有年份：同一個排程隔年同月日同時間的標記不能一樣（舊版一樣，去年那則還在紀錄檔尾端就把今年的當成已送出）
    D="$T/state"; mkdir -p "$D"
    launch "$D" --schedule-marker-probe "$T/out.txt"
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "probe 正常完成" "$([ -f "$T/out.txt" ] && echo 有 || echo 無)" "有"
    check "隔年標記不同" "$([ -f "$T/out.txt" ] && grep -c 'differ=true' "$T/out.txt" || true)" "1"
    check "舊格式標記（沒年份）可由新標記推出" "$([ -f "$T/out.txt" ] && grep -c '^legacy=〔codenv 排程 3/5 09:00 #' "$T/out.txt" || true)" "1"
    ;;
C35)
    # 闔蓋＋外接螢幕：(1) 外接掉線 2 秒不叫停聊天室、掉線超過防抖時間才開始撐著 (2) 外接螢幕闔蓋期間照樣有時間上限
    # (3) 虛擬／未知廠商／內建／睡眠中的螢幕不算實體外接。全部用假環境（--lid-sim），不碰真的闔蓋和 pmset
    D1="$T/s1"; D2="$T/s2"; D3="$T/s3"; mkdir -p "$D1" "$D2" "$D3"
    launch "$D1" --lid-sim "1:work=1" --lid-sim "2:display=1" --lid-sim "3:close" --lid-sim "6:display=0" --lid-sim "8:display=1" --lid-sim "12:display=0" --lid-limits "600,95,60,60,30,1"
    launch "$D2" --lid-sim "1:work=1" --lid-sim "2:display=1" --lid-sim "3:close" --lid-limits "5,95,60,60,30,1"
    launch "$D3" --lid-display-filter-probe "$D3/r.txt"
    sleep 24; stop
    L1="$D1/codenv-lid.log"; L2="$D2/codenv-lid.log"
    check "閃斷 2 秒：沒有立刻撐著或叫停" "$(awk '/display=0/{f++} /闔蓋，撐著/{ if (f==1) bad=1 } END{print bad?"有":"無"}' "$L1")" "無"
    check "持續掉線超過防抖才撐著" "$(grep -c '闔蓋，撐著讓它做完' "$L1")" "1"
    check "外接螢幕闔蓋撐到上限：放掉預擋" "$(grep -c '外接螢幕闔蓋期間不再擋睡眠' "$L2")" "1"
    check "  而且沒有主動睡（pmset sleepnow）" "$(grep -c 'sleepnow' "$L2")" "0"
    check "實體外接算外接" "$(grep -c 'real_external=true' "$D3/r.txt")" "1"
    check "內建／虛擬／睡眠中不算外接" "$(grep -c "=false" "$D3/r.txt")" "5"
    ;;
C36)
    # 桌寵進度通知塞 NaN／無限／1e30 的 total、done、eta：不能崩潰，連畫面重畫（items()）也要過
    D="$T/state"; mkdir -p "$D"
    launch "$D" --progress-fuzz "$T/out.txt"
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "沒崩潰、全部處理完" "$([ -f "$T/out.txt" ] && grep -c '^ok 7' "$T/out.txt" || true)" "1"
    ;;
C37)
    # 聊天網頁程序一直崩潰：1 分鐘內最多自動重載 3 次（ready 累計 1+3=4 次），之後不再重載，不能無限循環
    D="$T/state"; mkdir -p "$D" "$T/proj"
    launch "$D" --new-conv-at "1:$T/proj" --web-crash-loop-probe "5:$T/out.txt"
    for i in $(seq 1 60); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "probe 正常完成" "$([ -f "$T/out.txt" ] && echo 有 || echo 無)" "有"
    # 探測：連殺 5 次後先量 overlay_shown，再按「重新載入」按鈕，等 6 秒才寫 ready_count（1 次初始＋3 次自動重載＋1 次按鈕＝5）
    check "自動只重載了 3 次、再加按鈕 1 次" "$([ -f "$T/out.txt" ] && grep -c 'ready_count=5' "$T/out.txt" || true)" "1"
    check "放棄自動重載時有顯示原生提示" "$([ -f "$T/out.txt" ] && grep -c 'overlay_shown=true' "$T/out.txt" || true)" "1"
    check "按重新載入後提示收掉、網頁回來" "$([ -f "$T/out.txt" ] && grep -c 'overlay_after_reload=false' "$T/out.txt" || true)$([ -f "$T/out.txt" ] && grep -c 'ready_now=true' "$T/out.txt" || true)" "11"
    ;;
C38)
    # 闔蓋外接螢幕（續）：(1) Mac 睡醒後外接螢幕還沒回來，要有寬限，不能立刻當闔蓋叫停 (2) 狀態確認後重擋失敗，要把舊連線放掉。假環境，不碰真的闔蓋和 pmset
    D1="$T/s1"; D2="$T/s2"; mkdir -p "$D1" "$D2"
    launch "$D1" --lid-sim "1:work=1" --lid-sim "2:display=1" --lid-sim "3:close" --lid-sim "6:display=0" --lid-sim "6:jump=40" --lid-sim "14:display=1" --lid-limits "600,95,60,60,30,1"
    launch "$D2" --lid-sim "1:work=1" --lid-sim "2:close" --lid-sim "4:helper=fail" --lid-sim "5:extoff" --lid-sim "9:helper=ok" --lid-limits "600,95,60,60,30,1"
    sleep 22; stop
    L1="$D1/codenv-lid.log"; L2="$D2/codenv-lid.log"
    check "睡醒後有給外接螢幕寬限" "$(grep -c '剛從睡眠醒來，外接螢幕給' "$L1")" "1"
    check "寬限在撐著之前（不是醒來就叫停）" "$(awk '/剛從睡眠醒來/{w=NR} /闔蓋，撐著/{ if (w && NR>w) ok=1 } END{print ok?"是":"否"}' "$L1")" "是"
    check "重擋失敗會送 off 放掉舊連線" "$(awk '/nosleep on（fail）/{f=1} /nosleep off（fail）/{ if (f) ok=1 } END{print ok?"是":"否"}' "$L2")" "是"
    check "  並記下舊連線已放掉" "$(grep -c '舊連線已放掉' "$L2")" "1"
    ;;
C39)
    # 拖放暫存清理：超過一天、沒人引用的刪；草稿／寄件匣還指著的留著（草稿隔天重開檔案要還在）；新的留著。用暫存資料夾，不碰共用的真資料夾
    D="$T/state"; mkdir -p "$D"
    launch "$D" --drop-clean-probe "$T/out.txt"
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "沒人引用的舊項目被刪" "$([ -f "$T/out.txt" ] && grep -c 'unref_gone=true' "$T/out.txt" || true)" "1"
    check "草稿引用的舊項目留著" "$([ -f "$T/out.txt" ] && grep -c '^ref_kept=true' "$T/out.txt" || true)" "1"
    check "新項目留著" "$([ -f "$T/out.txt" ] && grep -c 'fresh_kept=true' "$T/out.txt" || true)" "1"
    check "被隔離的壞草稿（.json.bad-…）引用的也留著" "$([ -f "$T/out.txt" ] && grep -c 'bad_ref_kept=true' "$T/out.txt" || true)" "1"
    ;;
C40)
    # 背景自動跑的 git：(1) 狀態照常讀對（含 CRLF 的 repo 不出假變更） (2) 逾時要連忽略 TERM 的 git 和它的子程序整群砍掉。假 git，暫存資料夾
    D="$T/state"; mkdir -p "$D"
    launch "$D" --git-safety-probe "$T/out.txt"
    for i in $(seq 1 40); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "probe 正常完成" "$([ -f "$T/out.txt" ] && echo 有 || echo 無)" "有"
    # filter.<name>.clean 會不會被執行不斷言（已知限制：來自 repo 自己的 .git/config，擋不住；試過 --attr-source 會造成假變更而放棄）
    check "大小相同、內容不同的修改要偵測到（.gitattributes 的 filter）" "$([ -f "$T/out.txt" ] && grep -c 'changed_attr=1' "$T/out.txt" || true)" "1"
    check "  （.git/info/attributes 的 filter）" "$([ -f "$T/out.txt" ] && grep -c 'changed_info=1' "$T/out.txt" || true)" "1"
    check "CRLF＋eol=crlf 的 repo 不會多出假變更" "$([ -f "$T/out.txt" ] && grep -c 'crlf_changed=0' "$T/out.txt" || true)" "1"
    check "卡住的 git 逾時回 nil、不拖太久" "$([ -f "$T/out.txt" ] && grep -c 'timeout_nil=true' "$T/out.txt" || true)$([ -f "$T/out.txt" ] && grep -c 'timeout_fast=true' "$T/out.txt" || true)" "11"
    check "git 不存在：回 nil，不回空結果" "$([ -f "$T/out.txt" ] && grep -c 'missing_git_nil=true' "$T/out.txt" || true)" "1"
    check "右欄 RPShell 逾時整群砍、不拖太久" "$([ -f "$T/out.txt" ] && grep -c 'rpshell_timed_out=true' "$T/out.txt" || true)$([ -f "$T/out.txt" ] && grep -c 'rpshell_fast=true' "$T/out.txt" || true)" "11"
    check "子程序也被砍乾淨" "$([ -f "$T/out.txt" ] && grep -c 'leftover=0' "$T/out.txt" || true)" "1"
    ;;
C41)
    # 每週排程的 weekdays 含 0／負數／8：summary 不崩潰，超出 1...7 的濾掉（舊版 0 越界 trap、8 顯示成「日」）
    D="$T/state"; mkdir -p "$D"
    launch "$D" --schedule-summary-probe "$T/out.txt"
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "沒崩潰、全部算完" "$([ -f "$T/out.txt" ] && grep -c '^normal=' "$T/out.txt" || true)" "1"
    check "含 0 的：沒有選日子" "$([ -f "$T/out.txt" ] && grep -c '^zero=每週（沒有選日子）' "$T/out.txt" || true)" "1"
    check "含 8 的：8 被濾掉只剩週日" "$([ -f "$T/out.txt" ] && grep -c '^eight=每週日 ' "$T/out.txt" || true)" "1"
    check "正常的照舊（日、六）" "$([ -f "$T/out.txt" ] && grep -c '^normal=每週日、六 ' "$T/out.txt" || true)" "1"
    ;;
C42)
    # 換模型交接遇到大紀錄檔：主執行緒只讀檔尾（不卡），全文檔先寫檔尾版、背景補成完整版（舊版整份讀進主執行緒，三百多 MB 要好幾秒）
    D="$T/state"; mkdir -p "$D"
    python3 - "$T/big.jsonl" <<'PY'
import json, sys
pad = "x" * 20000
with open(sys.argv[1], "w") as f:
    f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "FIRSTMSG 最早的一句"}}, ensure_ascii=False) + "\n")
    f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "Read", "input": {"file_path": "/early/file.txt"}}]}}) + "\n")
    for i in range(3500):   # 約 70 MB 的工具輸出：交接時全部要被略過
        f.write(json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": pad + str(i)}]}}) + "\n")
    f.write(json.dumps({"type": "user", "message": {"role": "user", "content": "LASTQ 最後的問題"}}, ensure_ascii=False) + "\n")
    f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "LASTA 最後的回答"}]}}, ensure_ascii=False) + "\n")
PY
    launch "$D" --carry-time-probe "$T/big.jsonl:$T/out.txt"
    for i in $(seq 1 90); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "有算完" "$([ -f "$T/out.txt" ] && grep -c '^final_doc_partial=false' "$T/out.txt" || true)" "1"
    check "交接有最後一段對話" "$([ -f "$T/out.txt" ] && grep -c '^note_has_last=true' "$T/out.txt" || true)" "1"
    check "主執行緒那段不到 2 秒" "$([ -f "$T/out.txt" ] && awk -F= '/^sync_secs/{print ($2<2)?"是":"否"}' "$T/out.txt" || true)" "是"
    check "先寫的是檔尾版" "$([ -f "$T/out.txt" ] && grep -c '^first_doc_partial=true' "$T/out.txt" || true)" "1"
    DOC=$(ls "$D"/carry/*.md 2>/dev/null | head -1)
    check "最後的全文檔是完整版（有最早的一句）" "$([ -n "$DOC" ] && grep -c 'FIRSTMSG' "$DOC" || true)" "1"
    check "  也有最早讀過的檔" "$([ -n "$DOC" ] && grep -c '/early/file.txt' "$DOC" || true)" "1"
    ;;
C43)
    # 看板目標陣列混了一個不是字典的元素：新增目標／步驟不能把其他目標整串丟掉；寫回前留 .bak；goals 不是陣列就不寫
    D="$T/state"; mkdir -p "$D"
    python3 - "$D/collab.json" <<'PY'
import json, sys
g = {"id": "aaaaaa", "title": "舊目標", "status": "active", "at": "2026-11-08T00:00:00Z", "by": "x",
     "steps": [{"id": "s1", "text": "第一步", "state": "todo", "at": "2026-11-08T00:00:00Z"}, "壞步驟", 7]}
json.dump({"goals": ["壞目標", 7, g], "items": []}, open(sys.argv[1], "w"), ensure_ascii=False)
PY
    launch "$D" --collab-act "3|addgoal|新目標|完成|步驟一" --collab-act "5|addstep|aaaaaa|新步驟@x" --collab-act "7|step|aaaaaa|s1|doing"
    sleep 11; stop
    python3 - "$D/collab.json" > "$T/r.txt" <<'PY'
import json, sys
o = json.load(open(sys.argv[1])); gs = o["goals"]
old = [g for g in gs if isinstance(g, dict) and g.get("id") == "aaaaaa"]
print("count=%d" % len(gs))
print("garbage_kept=%s" % ("壞目標" in gs and 7 in gs))
print("new_goal=%s" % any(isinstance(g, dict) and g.get("title") == "新目標" for g in gs))
st = old[0]["steps"] if old else []
print("bad_steps_kept=%s" % ("壞步驟" in st and 7 in st))
print("new_step=%s" % any(isinstance(s, dict) and s.get("text") == "新步驟" for s in st))
print("step_edit=%s" % any(isinstance(s, dict) and s.get("id") == "s1" and s.get("state") == "doing" for s in st))
PY
    check "目標筆數（壞的兩筆＋舊的＋新的）" "$(grep -c '^count=4' "$T/r.txt")" "1"
    check "不是字典的目標原樣留著" "$(grep -c '^garbage_kept=True' "$T/r.txt")" "1"
    check "新目標寫進去了" "$(grep -c '^new_goal=True' "$T/r.txt")" "1"
    check "不是字典的步驟原樣留著" "$(grep -c '^bad_steps_kept=True' "$T/r.txt")" "1"
    check "加步驟成功" "$(grep -c '^new_step=True' "$T/r.txt")" "1"
    check "改步驟狀態成功" "$(grep -c '^step_edit=True' "$T/r.txt")" "1"
    check "寫回前留了 .bak" "$([ -f "$D/collab.json.bak" ] && echo 有 || echo 無)" "有"
    # goals 根本不是陣列：不寫
    D2="$T/state2"; mkdir -p "$D2"
    printf '{"goals":{"x":1},"items":[]}' > "$D2/collab.json"
    launch "$D2" --collab-act "3|addgoal|新目標|完成|步驟一"
    sleep 7; stop
    check "goals 不是陣列：內容不變、沒寫進新目標" "$(python3 -c "import json,sys;o=json.load(open(sys.argv[1]));print('是' if o['goals']=={'x':1} else '否')" "$D2/collab.json")" "是"
    ;;
C44)
    # state.json 與 .bak 都解不開：原檔位元組不能被空狀態蓋掉（本次不存檔），並另存一份「讀不到」
    D="$T/state"; mkdir -p "$D"
    printf '{"projects":[{"壞掉' > "$D/state.json"
    printf '{"也壞掉' > "$D/state.json.bak"
    cp "$D/state.json" "$T/before.json"; cp "$D/state.json.bak" "$T/before.bak"
    launch "$D" --new-conv-at "1:$T/proj"; sleep 9; stop
    check "state.json 位元組不變" "$(cmp -s "$D/state.json" "$T/before.json" && echo 是 || echo 否)" "是"
    check "state.json.bak 位元組不變" "$(cmp -s "$D/state.json.bak" "$T/before.bak" && echo 是 || echo 否)" "是"
    check "另存了一份讀不到" "$(ls "$D" | grep -c 'state.json.讀不到')" "1"
    # 正向對照：舊版只有最少欄位的 state.json 讀得進來
    D2="$T/state2"; mkdir -p "$D2"
    printf '{"projects":[{"id":"22222222-2222-2222-2222-222222222222","name":"p","path":"/tmp","expanded":true}],"conversations":[{"id":"11111111-1111-1111-1111-111111111111","projectID":"22222222-2222-2222-2222-222222222222","title":"舊","claudeSession":"11111111-1111-1111-1111-111111111111","createdAt":1000,"lastOpened":1000,"renamed":false}]}' > "$D2/state.json"
    launch "$D2"; sleep 8; stop
    check "舊版最少欄位的檔讀得進來（對話還在）" "$(convs "$D2/state.json")" "1"
    check "  沒有另存讀不到" "$(ls "$D2" | grep -c '讀不到')" "0"
    ;;
C45)
    # 缺鍵 decode 快照：sprint.json／schedules.json 的非 Optional 欄位有哪些（缺一個整份讀不出來）。有人新增欄位時這裡會變，
    # 要嘛改成 Optional（舊檔才讀得進來）、要嘛確認後更新這份快照。另：sprint.json 讀不懂時另存一份，不直接蓋掉
    D="$T/state"; mkdir -p "$D"
    printf '{"phase":"running"' > "$D/sprint.json"
    launch "$D" --decode-compat-probe "$T/out.txt"
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done; sleep 2; stop
    check "目前格式的 WakeSchedule 編了再讀得回來" "$(grep -c '^wake_roundtrip=true' "$T/out.txt")" "1"
    check "目前格式的 SprintState 編了再讀得回來" "$(grep -c '^sprint_roundtrip=true' "$T/out.txt")" "1"
    check "WakeSchedule 必填欄位快照" "$(grep '^wake_missing_fail=' "$T/out.txt")" "wake_missing_fail=conversation,createdAt,enabled,frequency,id,intervalMinutes,monthDays,runs,text,times,weekdays,whenClosed"
    check "SprintState 必填欄位快照" "$(grep '^sprint_missing_fail=' "$T/out.txt")" "sprint_missing_fail=baselineUsed,convTitle,endReason,goal,notes,nudges,phase,summary,summaryAuto,targetKnown,watchLabel,windSent"
    check "sprint.json 讀不懂：另存一份" "$(ls "$D" | grep -c 'sprint.json.讀不到')" "1"
    ;;
C46)
    # 螢幕開著預擋失敗：第一次照舊試，之後改背景重試＋退避；小幫手恢復後重試成功。假環境，不碰真的 pmset
    D="$T/state"; mkdir -p "$D"
    launch "$D" --lid-sim "0.5:helper=fail" --lid-sim "1:work=1" --lid-sim "5:helper=ok" --lid-limits "600,95,60,60,30,1,2"
    sleep 14; stop
    L="$D/codenv-lid.log"
    check "預擋失敗只記一次" "$(grep -c '預擋失敗' "$L")" "1"
    check "小幫手恢復後背景重試成功" "$(grep -c '預擋：有 1 段工作中，先讓 Mac 不睡（重試成功）' "$L")" "1"
    ;;
C47)
    # 測試實例：(1) 給子程序的環境變數指到測試資料夾（codenv-todo／codenv-browser 不會連到正式看板和正式 codenv）
    # (2) --state-dir 後面沒給資料夾要報錯結束，不落回正式資料 (3) --test-screen 找不到螢幕就照舊、找得到就擺進去
    D="$T/state"; mkdir -p "$D"
    launch "$D" --env-probe "$T/out.txt" --test-screen 不存在的螢幕名
    for i in $(seq 1 30); do [ -s "$T/out.txt" ] && break; sleep 1; done; sleep 1; stop
    check "CODENV_COLLAB_FILE 指到測試資料夾" "$(grep -c "^CODENV_COLLAB_FILE=$D/collab.json\$" "$T/out.txt")" "1"
    check "CODENV_BROWSER_DIR 指到測試資料夾" "$(grep -c "^CODENV_BROWSER_DIR=$D/browser\$" "$T/out.txt")" "1"
    check "CODENV_STATE_DIR 指到測試資料夾" "$(grep -c "^CODENV_STATE_DIR=$D\$" "$T/out.txt")" "1"
    "$BIN" --state-dir > "$T/err.txt" 2>&1; rc=$?
    check "--state-dir 缺值：報錯結束（exit 2）" "$rc" "2"
    # --test-screen：挑一台不是主螢幕的（沒有第二台就跳過），視窗要整個落在它的可用範圍裡
    SCR=$(python3 -c "
import re
for l in open('$T/out.txt'):
    if l.startswith('screens='):
        n=l.strip()[8:].split('|')
        print(n[-1] if len(n)>1 else '')")
    if [ -n "$SCR" ]; then
        D2="$T/state2"; mkdir -p "$D2"
        launch "$D2" --env-probe "$T/out2.txt" --test-screen "$SCR"
        for i in $(seq 1 30); do [ -s "$T/out2.txt" ] && break; sleep 1; done; sleep 1; stop
        check "視窗在指定螢幕上" "$(grep -c "^window_screen=$SCR\$" "$T/out2.txt")" "1"
        check "  整個在可用範圍內" "$(grep -c '^window_inside_visible=true' "$T/out2.txt")" "1"
    else echo "  （只有一台螢幕，略過 --test-screen 的擺放測試）"; fi
    ;;
C48)
    # 換模型交接的兩個回歸：(1) A（大檔）→ B（小檔）連換兩次，背景補完的全文檔不能把 B 蓋成 A (2) 最後一行超過檔尾窗，不能回 nil
    D="$T/state"; mkdir -p "$D"
    python3 - "$T" <<'PY'
import json, sys
T = sys.argv[1]
def line(t, text): return json.dumps({"type": t, "message": {"role": t, "content": text if t == "user" else [{"type": "text", "text": text}]}}, ensure_ascii=False) + "\n"
pad = json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "x" * 20000}]}}) + "\n"
with open(T + "/A.jsonl", "w") as f:
    f.write(line("user", "AAAA 甲的問題")); f.write(line("assistant", "AAAA 甲的回答"))
    for _ in range(3000): f.write(pad)       # 約 60 MB：會被截斷、排背景補全文
    f.write(line("user", "AAAA 甲最後的問題")); f.write(line("assistant", "AAAA 甲最後的回答"))
with open(T + "/B.jsonl", "w") as f:
    f.write(line("user", "BBBB 乙的問題")); f.write(line("assistant", "BBBB 乙的回答"))
with open(T + "/L.jsonl", "w") as f:
    f.write(line("user", "LONGFIRST 很早的問題")); f.write(line("assistant", "LONGFIRST 很早的回答"))
    f.write(json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "content": "y" * (40 * 1024 * 1024)}]}}) + "\n")   # 最後一行 40 MB
PY
    launch "$D" --carry-race-probe "$T/A.jsonl:$T/B.jsonl:$T/L.jsonl:$T/out.txt"
    for i in $(seq 1 90); do [ -s "$T/out.txt" ] && break; sleep 1; done; stop
    check "兩次都有交接" "$([ -f "$T/out.txt" ] && grep -c '^noteA_nil=false' "$T/out.txt" || true)$([ -f "$T/out.txt" ] && grep -c '^noteB_nil=false' "$T/out.txt" || true)" "11"
    check "全文檔是乙的（背景補完沒蓋回甲）" "$([ -f "$T/out.txt" ] && grep -c '^doc_has_B=true' "$T/out.txt" || true)" "1"
    check "  沒有甲的內容" "$([ -f "$T/out.txt" ] && grep -c '^doc_has_A=false' "$T/out.txt" || true)" "1"
    check "最後一行超過窗：放大讀取，仍有交接" "$([ -f "$T/out.txt" ] && grep -c '^long_nil=false' "$T/out.txt" || true)" "1"
    check "  交接裡有很早的對話" "$([ -f "$T/out.txt" ] && grep -c '^long_has_text=true' "$T/out.txt" || true)" "1"
    ;;
C49)
    # 看板 .bak 不被緊接的下一次寫入洗掉：元素變少的寫入不換 .bak；欄位格式不對時不再無聲失效（記事件紀錄）
    D="$T/state"; mkdir -p "$D"
    python3 - "$D/collab.json" <<'PY'
import json, sys
mk = lambda i: {"id": i, "title": "目標" + i, "status": "active", "at": "2026-11-08T00:00:00Z", "by": "x", "steps": [{"id": "s" + i, "text": "步", "state": "todo", "at": "2026-11-08T00:00:00Z"}]}
json.dump({"goals": [mk("g1"), mk("g2"), mk("g3")], "items": []}, open(sys.argv[1], "w"), ensure_ascii=False)
PY
    launch "$D" --collab-act "3|addgoal|新的|完成|步驟" --collab-act "5|delgoal|g1" --collab-act "7|delgoal|g2" --collab-act "9|step|g3|sg3|doing"
    sleep 13; stop
    check "目前剩 2 個目標（g3＋新的）" "$(python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))['goals']))" "$D/collab.json")" "2"
    check ".bak 還是最早那版（g1、g2 都還在，沒被連刪兩次洗掉）" "$(python3 -c "import json,sys;ids=[g['id'] for g in json.load(open(sys.argv[1]))['goals']];print('是' if 'g1' in ids and 'g2' in ids else '否')" "$D/collab.json.bak" 2>/dev/null || echo 無)" "是"
    D2="$T/state2"; mkdir -p "$D2"
    printf '{"goals":[],"items":"壞的"}' > "$D2/collab.json"
    launch "$D2" --collab-act "3|done|abc"
    sleep 7; stop
    check "items 格式不對：事件紀錄有留一行" "$(cat "$D2"/events/* 2>/dev/null | grep -c 'items 格式不對')" "1"
    check "  原檔沒動（items 仍是壞的字串）" "$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['items'])" "$D2/collab.json")" "壞的"
    ;;
*) echo "沒有這個原生案例：$ID"; exit 1 ;;
esac
exit $fail
