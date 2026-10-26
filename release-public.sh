#!/bin/bash
# 公版出版（本機做好，不自動上傳）：./release-public.sh [說明]
# 1. 在這個資料夾裡打 tag v<版本>（版本讀 Info.plist）
# 2. 用臨時簽章（ad-hoc）編譯，做成 dmg 放進 dist/
# 3. 最後印出要執行的 gh release create 指令，由你確認後自己跑；這支腳本不 push、不建 repo、不發 Release
set -euo pipefail
cd "$(dirname "$0")"
REPO="${CODENV_RELEASE_REPO:-olilllioli287/codenv-public}"
VER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
TAG="v$VER"
NOTES="${1:-codenv $VER}"
[ -z "$(git status --porcelain)" ] || { echo "有還沒 commit 的檔案，先 commit"; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && echo "$TAG 已經有了，沿用" || git tag -a "$TAG" -m "codenv $VER"

WORK=$(mktemp -d /tmp/codenv-public.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/dmg" "$WORK/src" dist
# 在中性的暫存資料夾裡編譯已 commit 的內容：這個資料夾的路徑（含你的使用者名稱）就不會被編進執行檔（#filePath 會把原始碼的完整路徑寫進去）
git archive HEAD | tar -x -C "$WORK/src"
CODENV_SIGN_IDENTITY=- APP="$WORK/dmg/codenv.app" "$WORK/src/build.sh" --no-open --no-register

# 檢查：做好的 App 裡面不能有你的家目錄路徑或使用者名稱
LEAK=0
for NEEDLE in "$HOME" "$(id -un)"; do
    [ -n "$NEEDLE" ] || continue
    while IFS= read -r -d '' F; do
        HIT=$(strings -a "$F" 2>/dev/null | grep -F -m3 -- "$NEEDLE" || true)
        if [ -n "$HIT" ]; then echo "發現 \"$NEEDLE\"：${F#$WORK/dmg/}"; echo "$HIT" | sed 's/^/    /'; LEAK=1; fi
    done < <(find "$WORK/dmg/codenv.app" -type f -print0)
done
[ "$LEAK" = 0 ] || { echo "App 裡有你的個人路徑或名稱，沒有做 dmg"; exit 2; }
echo "檢查：App 裡沒有家目錄路徑或使用者名稱"
ln -s /Applications "$WORK/dmg/Applications"
DMG="dist/codenv-$VER.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "codenv $VER" -srcfolder "$WORK/dmg" -ov -format UDZO "$DMG"
echo "做好：${DMG}（$(du -h "$DMG" | cut -f1)）"

cat <<EOM

確認沒問題後，自己執行下面兩行（第一次要先 gh repo create）：

  git push origin main "$TAG"
  gh release create "$TAG" "$DMG" -R "$REPO" --title "codenv $VER" --notes "$NOTES

## 安裝
下載 codenv-$VER.dmg，拖進「應用程式」。第一次打開對 codenv 按右鍵 →「打開」→「打開」（臨時簽章，沒有 Apple 開發者簽名）。更新後系統權限可能要重新給一次。"
EOM
