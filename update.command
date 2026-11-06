#!/bin/bash
# 把官方的新版合進你自己（改裝過）的 codenv，重新編譯安裝；你的改動會保留。
# 用法：在 Finder 對這個檔案點兩下（或在終端機執行 ./update.command）。
# 它只會：fetch 官方、git merge、編譯安裝。不會 reset、不會 rebase、不會自動 stash 或 commit，也不會推到任何地方。
#
# 測試／進階用的環境變數：
#   CODENV_UPSTREAM_URL   官方 repo 網址（預設 https://github.com/olilllioli287/codenv-public.git）
#   CODENV_UPSTREAM_BRANCH 要合的分支（預設 main）
#   CODENV_BUILD_CMD      編譯安裝的指令（預設 ./build.sh）
#   APP                   build.sh 安裝到哪（預設 ~/Applications/codenv.app）
#   CODENV_NO_PAUSE=1     結束時不等按鍵

OFFICIAL_URL="${CODENV_UPSTREAM_URL:-https://github.com/olilllioli287/codenv-public.git}"
BRANCH="${CODENV_UPSTREAM_BRANCH:-main}"
BUILD_CMD="${CODENV_BUILD_CMD:-./build.sh}"

pause() {
    [ -n "${CODENV_NO_PAUSE:-}" ] && return
    echo
    read -n 1 -s -r -p "按任意鍵關閉視窗…"
    echo
}
# 每個出口都先等按鍵：雙擊開的終端機結束就會關，不等的話看不到結果
die() { echo; echo "✗ $*"; pause; exit 1; }
say() { echo "▶ $*"; }

cd "$(dirname "$0")" || die "找不到腳本所在的資料夾。"

# 1. 環境
command -v git >/dev/null 2>&1 || die "找不到 git。請在終端機執行  xcode-select --install  安裝命令列工具，裝好再點兩下這個檔案。"
command -v swift >/dev/null 2>&1 || die "找不到 swift（編譯用）。請執行  xcode-select --install  安裝命令列工具，或安裝 Xcode，裝好再試。"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "這個資料夾不是 git 倉庫（可能是下載的 zip）。請用  git clone  取得 codenv，更新腳本才能合併。"
ROOT="$(git rev-parse --show-toplevel)"
[ "${ROOT}" = "$(pwd -P)" ] || cd "${ROOT}" || die "進不了倉庫根目錄。"

# 2. 有沒有沒 commit 的改動（沒追蹤的新檔案不算，不影響合併）
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    git status --short --untracked-files=no
    die "有還沒 commit 的改動（上面列出的）。請先 commit（或自己決定怎麼處理），這個腳本不會替你 stash 或 commit。"
fi

# 3. 不能在合併、rebase、cherry-pick 中，也不能是 detached HEAD
for f in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD; do
    [ -e "$(git rev-parse --git-path "${f}")" ] && die "目前正在進行合併／rebase／cherry-pick（${f}）。請先完成或中止它（例如  git merge --abort  或  git rebase --abort），再執行更新。"
done
git symbolic-ref -q HEAD >/dev/null 2>&1 || die "目前是 detached HEAD（不在任何分支上）。請先  git switch <你的分支>  再更新。"
CUR_BRANCH="$(git symbolic-ref --short HEAD)"

# 4. 找官方遠端：已有 upstream 就不動；沒有 upstream 但 origin 本身就是官方 repo 就直接用 origin；否則加一個 upstream（不碰 origin）
norm() { echo "$1" | sed -E 's#\.git$##; s#^git@github.com:#https://github.com/#' | tr 'A-Z' 'a-z'; }
OFFICIAL_N="$(norm "${OFFICIAL_URL}")"
if git remote get-url upstream >/dev/null 2>&1; then
    REMOTE=upstream
    say "使用既有的 upstream 遠端：$(git remote get-url upstream)"
elif [ "$(norm "$(git remote get-url origin 2>/dev/null || echo)")" = "${OFFICIAL_N}" ]; then
    REMOTE=origin
    say "origin 本身就是官方 repo，直接用它。"
else
    git remote add upstream "${OFFICIAL_URL}" || die "加不進 upstream 遠端。"
    REMOTE=upstream
    say "已新增 upstream 遠端：${OFFICIAL_URL}（只新增一次，你的 origin 沒動）"
fi

# 5. 記下目前位置，出事可以回來
BEFORE="$(git rev-parse HEAD)"
echo
echo "目前在分支 ${CUR_BRANCH}，commit：$(git rev-parse --short HEAD)"
echo "要還原到更新前：  git reset --hard ${BEFORE}   （合併還沒 commit 就停住時，用  git merge --abort）"
echo

# 6. 抓官方新版
say "抓官方最新版（${REMOTE}）…"
git fetch "${REMOTE}" "${BRANCH}" || die "fetch 失敗（網路、或遠端網址不對）。你的程式碼沒動。"
TARGET="FETCH_HEAD"
THEIRS="$(git rev-parse "${TARGET}")" || die "抓到了但讀不到 ${BRANCH}。你的程式碼沒動。"
if git merge-base --is-ancestor "${THEIRS}" HEAD; then
    echo; echo "✓ 已經是最新版，沒有要合併的東西。"
    pause; exit 0
fi
VER="$(git show "${THEIRS}:Info.plist" 2>/dev/null | sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' | head -1)"
COUNT="$(git rev-list --count "HEAD..${THEIRS}")"
echo "將合併官方 ${BRANCH}：${VER:+版本 ${VER}，}${COUNT} 個新的 commit："
git log --oneline "HEAD..${THEIRS}" | head -15
[ "${COUNT}" -gt 15 ] && echo "…（只列最近 15 個）"
echo

# 7. 合併（不 force、不 reset、不 rebase）
say "合併中…"
if ! git merge --no-edit -m "合併官方 ${BRANCH}${VER:+（版本 ${VER}）}" "${THEIRS}"; then
    echo
    if git diff --name-only --diff-filter=U | grep -q .; then
        echo "✗ 合併有衝突（你改過的地方和官方新版改到同一處）。衝突的檔案："
        git diff --name-only --diff-filter=U | sed 's/^/   /'
        echo
        echo "怎麼辦："
        echo "  • 想先放著：  git merge --abort   （一切回到更新前，你的版本完全沒動）"
        echo "  • 想自己解：打開上面的檔案，找 <<<<<<< ======= >>>>>>> 的標記，改成你要的樣子，"
        echo "    然後  git add <檔案>  再  git commit，最後重新點兩下這個檔案編譯。"
        echo "為了安全，這次不會編譯。"
    else
        echo "✗ 合併沒成功（不是一般衝突，可能是兩邊歷史不相關）。看上面的訊息；要回到更新前：  git merge --abort"
    fi
    pause; exit 1
fi
echo "✓ 合併完成（你的改動和官方新版都在）。"
echo

# 8. 編譯安裝
say "編譯並安裝（要幾分鐘）…"
if ! ${BUILD_CMD}; then
    echo
    echo "✗ 編譯失敗。程式碼已經合併進你的分支，但舊的 codenv App 沒動，還能照常用。"
    echo "  還原合併：  git reset --hard ${BEFORE}"
    echo "  或留著合併結果，看上面的錯誤訊息自己修。"
    pause; exit 1
fi

# 9. 結尾提醒
echo
echo "✓ 更新完成。"
echo
echo "提醒："
echo "  • 沒有你自己的簽章憑證時，build.sh 會用臨時簽章（ad-hoc）：App 重新簽章後，macOS 可能要你重新給「輔助使用」「螢幕錄製」等權限。"
echo "  • 如果你沒改過 Info.plist 的更新來源（CodenvUpdateRepo）和 Bundle ID，App 仍會提示有官方的 dmg 可以更新；"
echo "    裝官方 dmg 會把你改裝過的版本蓋掉。要保留改裝，請用這個腳本更新，不要裝 dmg。"
pause
exit 0
