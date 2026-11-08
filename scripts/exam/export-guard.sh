#!/bin/bash
# 考卷 C28：export-public.sh 的目的地防呆。用法：export-guard.sh <案例 ID> <repo 根目錄>
# 全部用暫存資料夾和假的 HOME（就算防呆壞了，被 rsync --delete 的也只是暫存資料夾，不是真的家目錄）
set -u
ROOT="${2:?}"
T=$(mktemp -d /tmp/codenv-exam-export.XXXXXX)
trap 'rm -rf "$T" "$T"-*review.txt "$T"/*-review.txt' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "  斷言通過：$1"; else echo "  斷言失敗：$1（期望 $3，實際 $2）"; fail=1; fi; }
FAKEHOME="$T/home"; mkdir -p "$FAKEHOME"
export_to() { # <目的地> [額外環境...]；回傳 exit code，輸出在 $T/out.txt
    local dest="$1"; shift
    env HOME="$FAKEHOME" CODENV_PUBLIC_DIR="$dest" "$@" bash "$ROOT/scripts/export-public.sh" --worktree > "$T/out.txt" 2>&1; echo $?
}
# 1. 非空、不是 git 的資料夾：拒絕，裡面的檔案還在
mkdir -p "$T/notrepo"; echo precious > "$T/notrepo/mine.txt"
check "非空的非 repo 資料夾：拒絕" "$(export_to "$T/notrepo")" "4"
check "  裡面的檔案還在" "$([ -f "$T/notrepo/mine.txt" ] && echo 在 || echo 不見)" "在"
# 2. 目的地是（假的）家目錄：拒絕
echo precious > "$FAKEHOME/mine.txt"
check "目的地是家目錄：拒絕" "$(export_to "$FAKEHOME")" "4"
check "  家目錄的檔案還在" "$([ -f "$FAKEHOME/mine.txt" ] && echo 在 || echo 不見)" "在"
# 3. 有 .git 但不是公版（沒有 codenv-public remote、也沒有標記）：拒絕
mkdir -p "$T/other"; git -C "$T/other" init -q; echo precious > "$T/other/mine.txt"
check "別人的 git repo：拒絕" "$(export_to "$T/other")" "4"
check "  檔案還在" "$([ -f "$T/other/mine.txt" ] && echo 在 || echo 不見)" "在"
# 4. 不存在的資料夾：第一次匯出成功並 git init；再匯出一次也成功
check "新資料夾第一次匯出成功" "$(export_to "$T/pub")" "0"
check "  有 .git" "$([ -d "$T/pub/.git" ] && echo 有 || echo 無)" "有"
check "再匯出一次成功" "$(export_to "$T/pub")" "0"
# 5. remote 指向 codenv-public 的 repo 可以同步
git -C "$T/pub" config --unset codenv.publicExport; git -C "$T/pub" remote add origin https://github.com/x/codenv-public.git
check "remote 指向 codenv-public 可同步" "$(export_to "$T/pub")" "0"
# 6a. 目的地尾端帶 /：第一次匯出照樣成功（review 檔不能寫進目的地裡）
check "尾端帶斜線的新資料夾可匯出" "$(export_to "$T/slash/")" "0"
# 6a2. 目的地以 /. 結尾會被正規化；以 - 開頭拒絕
check "目的地以 /. 結尾可匯出" "$(export_to "$T/dot/.")" "0"
check "目的地以 - 開頭：拒絕" "$(export_to "-evil")" "4"
# 6b. 含冒號：拒絕；超長的門檻數字：拒絕
check "目的地含冒號：拒絕" "$(export_to "$T/host:path")" "4"
check "門檻數字超長：拒絕" "$(export_to "$T/pub" CODENV_EXPORT_MAX_DELETE=99999999999999999999)" "4"
# 6c. remote 路徑含空白、只是前面像：不算公版
mkdir -p "$T/fake"; git -C "$T/fake" init -q; git -C "$T/fake" remote add origin "https://x/repos/codenv-public backup.git"; echo precious > "$T/fake/mine.txt"
check "remote 路徑含空白的假公版：拒絕" "$(export_to "$T/fake")" "4"
# 6. 要刪的檔太多：停下來；調高門檻才放行
for i in $(seq 1 40); do echo x > "$T/pub/extra-$i.txt"; done
check "要刪 40 個檔：超過門檻停下" "$(export_to "$T/pub")" "5"
check "  多出來的檔還在" "$([ -f "$T/pub/extra-1.txt" ] && echo 在 || echo 不見)" "在"
check "調高門檻後放行" "$(export_to "$T/pub" CODENV_EXPORT_MAX_DELETE=100)" "0"
check "  多出來的檔被清掉" "$([ -f "$T/pub/extra-1.txt" ] && echo 在 || echo 不見)" "不見"
exit $fail
