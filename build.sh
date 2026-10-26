#!/bin/bash
# 建置並安裝 codenv 到 ~/Applications。加 --no-open 就只裝不開
# 出版本（release.sh）時用 APP=別的位置 ./build.sh --no-open --no-register：只做出 App，不登記給系統（不然系統會有兩個 codenv）
set -e
cd "$(dirname "$0")"
APP="${APP:-$HOME/Applications/codenv.app}"
# 簽章用的憑證名字：環境變數 CODENV_SIGN_IDENTITY > 同資料夾的 .sign-identity 檔（私人版放自己的自簽憑證名字，公版匯出時不帶）> 臨時簽名（-）
IDENTITY="${CODENV_SIGN_IDENTITY:-$(cat .sign-identity 2>/dev/null || echo -)}"
# 指定的憑證不在這台電腦（別人的電腦）就用臨時簽名，一樣能跑
# 自簽憑證不在系統信任清單裡：不能加 -v（只列受信任的），不然會一直退回臨時簽章，每次編譯完整磁碟取用權限都會掉
[ "$IDENTITY" = "-" ] || security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\"" || IDENTITY=-

echo "編譯…"
swift build -c release

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
# 先刪再放：正在跑的 App 還用著舊檔（不同的檔案），不會被改到一半而當掉，下次打開才換新版
rm -f "$APP/Contents/MacOS/Workbench"
cp .build/release/Workbench "$APP/Contents/MacOS/Workbench"
# 聊天介面的網頁畫面（測試頁不放進去）
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$APP/Contents/Resources/chat"
rsync -a --exclude test.html Resources/chat "$APP/Contents/Resources/"
# 程式碼學習專區的編輯器（Monaco）
rm -rf "$APP/Contents/Resources/codelab"
rsync -a Resources/codelab "$APP/Contents/Resources/"
# 程式碼學習專區的 compat（Windows 寫的程式在 Mac 上也能跑；CodeRunner.swift 用）
rm -rf "$APP/Contents/Resources/compat"
rsync -a Resources/compat "$APP/Contents/Resources/"
rm -rf "$APP/Contents/Resources/i18n"
rsync -a Resources/i18n "$APP/Contents/Resources/"   # 英文介面的對照表（I18n.swift 用）
rm -rf "$APP/Contents/Resources/icons"
rsync -a Resources/icons "$APP/Contents/Resources/"   # 模型選單分頁的圖示（Claude、Gemini）

# 舊簽名留著會讓 codesign 吐 errSecInternalComponent，一定要先清掉
rm -rf "$APP/Contents/_CodeSignature"
codesign --force --sign "$IDENTITY" "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
# 換圖示時 Finder／Dock 會一直用快取的舊圖：更新修改時間＋重新登記，下次開 App 就換新
touch "$APP" "$APP/Contents/Info.plist"
[[ " $* " == *" --no-register "* ]] || /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

[ "$1" = "--no-open" ] || open "$APP"
echo "完成"
