#!/bin/bash
# 考卷 K01：金鑰管理核心（樣式偵測、誤攔、遮罩、鑰匙圈）。不開 App，把 KeyVault.swift 單獨編起來跑。
# 鑰匙圈只用 codenv-test-<亂數>- 前綴的測試項目，結束時刪掉；不碰 codenv-nvidia、codenv-openrouter 等真的項目。
set -u
ROOTDIR="${2:-$(cd "$(dirname "$0")/../.." && pwd)}"
T=$(mktemp -d /tmp/codenv-exam-keyvault.XXXXXX); trap 'rm -rf "$T"' EXIT
cp "$ROOTDIR/Sources/Workbench/KeyVault.swift" "$T/KeyVault.swift"
cp "$ROOTDIR/scripts/exam/keyvault/main.swift" "$T/main.swift"
# Transcripts.redactedJSON 單獨抽出來測（整個 Transcripts.swift 牽涉太多別的東西）
python3 - "$ROOTDIR/Sources/Workbench/Transcripts.swift" "$T/Redacted.swift" <<'PY'
import sys
s=open(sys.argv[1]).read()
a=s.index("    static func redactedJSON"); b=s.index("    /// 紀錄每筆的 timestamp")
open(sys.argv[2],"w").write("import Foundation\nenum Transcripts {\n"+s[a:b]+"}\n")
PY
swiftc -O -o "$T/kv" "$T/KeyVault.swift" "$T/Redacted.swift" "$T/main.swift" 2>&1 | grep -E "error" && exit 1
"$T/kv"
