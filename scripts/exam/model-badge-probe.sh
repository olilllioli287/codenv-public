#!/bin/bash
# 考卷 C492：任務面板「正在跑」模型徽章（agyp／dspublic／dsfree／dsh-safe／qwenapi／groqfree／gemfree）
# 與 ModelPopover 分頁數不變（純邏輯、不開 App、直接編譯並執行正式原始碼）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOTDIR="${2:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"
T="$(mktemp -d -t codenv-exam-modelbadge)"
trap 'rm -rf "$T"' EXIT

python3 - "$ROOTDIR" "$T" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
out = Path(sys.argv[2])

# 1. 從 AgyBridge.swift 原樣抽出 models／fixedModels／name／levels／level／base
agy_src = (root / "Sources/Workbench/AgyBridge.swift").read_text(encoding="utf-8")
a_start = agy_src.index("    static let models:")
a_end = agy_src.index("    /// 實際要開的模型")
(out / "AgySlice.swift").write_text(
    "import Foundation\nfinal class AgyBridge {\n" + agy_src[a_start:a_end] + "}\n",
    encoding="utf-8",
)

# 2. 從 Activity.swift 原樣抽出 externalModel／prettyGeminiModel 與 ModelBadge
act_src = (root / "Sources/Workbench/Activity.swift").read_text(encoding="utf-8")
e_start = act_src.index("    /// 從指令文字看得出它叫了哪個外部模型")
e_end = act_src.index("    /// 子代理指定的模型")
b_start = act_src.index("enum ModelBadge {")
b_end = act_src.index("struct ModelBadgeView: View")
(out / "ActivitySlice.swift").write_text(
    "import Foundation\n"
    "enum SessionActivity {\n"
    + act_src[e_start:e_end]
    + "}\n\n"
    + act_src[b_start:b_end],
    encoding="utf-8",
)

# 3. 從 ProcessScan.swift 原樣抽出 names
ps_src = (root / "Sources/Workbench/ProcessScan.swift").read_text(encoding="utf-8")
p_line = next(line for line in ps_src.splitlines() if "static let names:" in line)
(out / "ProcessScanSlice.swift").write_text(
    "import Foundation\nenum ProcessScan {\n" + p_line + "\n}\n",
    encoding="utf-8",
)

# 4. 從 ModelPopover.swift 原樣抽出 ModelRow／ModelTab／ModelPanelModel（不含 SwiftUI View 巨集，保留原 #filePath 讓 Resources/icons 載入真實 SVG）
pop_path = (root / "Sources/Workbench/ModelPopover.swift").resolve()
pop_src = pop_path.read_text(encoding="utf-8")
p_start = pop_src.index("struct ModelRow:")
p_end = pop_src.index("struct ModelPanel: View")
p_line_no = pop_src[:p_start].count("\n") + 1
escaped_pop_path = str(pop_path).replace("\\", "\\\\").replace('"', '\\"')
(out / "ModelPopoverSlice.swift").write_text(
    "import Foundation\nimport AppKit\nimport Combine\n"
    f'#sourceLocation(file: "{escaped_pop_path}", line: {p_line_no})\n'
    + pop_src[p_start:p_end]
    + "#sourceLocation()\n",
    encoding="utf-8",
)

# 5. 最小化 stub（僅供編譯真實的 ModelPopoverSlice）
(out / "Stubs.swift").write_text(
    """import Foundation
func L(_ s: String) -> String { s }
enum Effort {
    static let order = ["low", "medium", "high", "xhigh", "max"]
    static func name(_ s: String) -> String { s }
}
""",
    encoding="utf-8",
)
PY

cat > "$T/main.swift" <<'SWIFT'
import Foundation
import AppKit

var total = 0
var fails = 0

func check(_ ok: Bool, _ label: String, detail: String = "") {
    total += 1
    if ok {
        print("  通過：\(label)")
    } else {
        print("  失敗：\(label)\(detail.isEmpty ? "" : "（\(detail)）")")
        fails += 1
    }
}

func assertBadge(_ cmd: String, expectedTag: String, expectedTab: ModelTab?, expectedText: String, label: String) {
    let tag = SessionActivity.externalModel(in: cmd)
    check(tag == expectedTag, "\(label) — externalModel", detail: "預期 \(expectedTag)，實際 \(String(describing: tag))")
    if let tag {
        let info = ModelBadge.info(tag)
        check(info.tab == expectedTab && info.text == expectedText,
              "\(label) — ModelBadge.info",
              detail: "預期 (\(String(describing: expectedTab)), \(expectedText))，實際 (\(String(describing: info.tab)), \(info.text))")
    }
}

// 1. 題目指定驗收案例
assertBadge("agyp --model gemini-4-neon-xhigh",
            expectedTag: "Gemini 4 Neon・xhigh", expectedTab: .gemini, expectedText: "Neon・xhigh",
            label: "agyp --model gemini-4-neon-xhigh")

assertBadge("dspublic --public -m deepseek-flash",
            expectedTag: "DeepSeek deepseek-flash", expectedTab: .deepseek, expectedText: "Flash",
            label: "dspublic --public -m deepseek-flash")

assertBadge("qwenapi --public",
            expectedTag: "Qwen", expectedTab: .qwen, expectedText: "",
            label: "qwenapi --public")

assertBadge("qwenapi --public -m qwen4-max",
            expectedTag: "Qwen qwen4-max", expectedTab: .qwen, expectedText: "Qwen4 Max",
            label: "qwenapi --public -m qwen4-max")

assertBadge("dsh-safe \"x\"",
            expectedTag: "DeepSeek", expectedTab: .deepseek, expectedText: "",
            label: "dsh-safe \"x\"")

assertBadge("groqfree",
            expectedTag: "Groq", expectedTab: .groq, expectedText: "",
            label: "groqfree")

assertBadge("gemfree",
            expectedTag: "Gemini", expectedTab: .gemini, expectedText: "",
            label: "gemfree")

assertBadge("echo x | dspublic --public",
            expectedTag: "DeepSeek", expectedTab: .deepseek, expectedText: "",
            label: "echo x | dspublic --public")

// 2. 只是提到名字不該認
for ignored in ["grep agyp", "grep agyp foo.txt", "which dspublic", "echo qwenapi groqfree gemfree", "cat dsh-safe.log"] {
    let tag = SessionActivity.externalModel(in: ignored)
    check(tag == nil, "不誤認：\(ignored)", detail: "預期 nil，實際 \(String(describing: tag))")
}

// 3. 補充案例（管線含 -m、環境變數前綴、dsfree、groqfree -m、gemfree -m、agyp 無 -m／Claude、既有回歸）
assertBadge("cat diff.txt | dspublic --public -m deepseek-flash",
            expectedTag: "DeepSeek deepseek-flash", expectedTab: .deepseek, expectedText: "Flash",
            label: "管線後段 dspublic 帶 -m")

assertBadge("AGYP_ACCOUNT=agy2 agyp --model gemini-4-neon-xhigh -p hi",
            expectedTag: "Gemini 4 Neon・xhigh", expectedTab: .gemini, expectedText: "Neon・xhigh",
            label: "環境變數前綴＋agyp")

assertBadge("agyp -p hi",
            expectedTag: "agy", expectedTab: .gemini, expectedText: "agy",
            label: "agyp 未指定模型")

assertBadge("agyp --model claude-sonnet-5-5-high -p hi",
            expectedTag: "Claude Sonnet 5.5・high", expectedTab: .claude, expectedText: "Sonnet 5.5・high",
            label: "agyp 跑 Claude 模型")

assertBadge("dsfree \"review\"",
            expectedTag: "DeepSeek", expectedTab: .deepseek, expectedText: "",
            label: "dsfree")

assertBadge("qwenapi --public -m qwen-max",
            expectedTag: "Qwen qwen-max", expectedTab: .qwen, expectedText: "Max",
            label: "qwenapi -m qwen-max")

assertBadge("groqfree -m llama-3.3-70b",
            expectedTag: "Groq llama-3.3-70b", expectedTab: .groq, expectedText: "Llama 3.3 70b",
            label: "groqfree 帶 -m")

assertBadge("gemfree -m gemini-3.8-flash",
            expectedTag: "Gemini 3.8 Flash", expectedTab: .gemini, expectedText: "3.8 Flash",
            label: "gemfree 帶 -m")

assertBadge("agy --model gemini-4-argon-high",
            expectedTag: "Gemini 4 Argon・high", expectedTab: .gemini, expectedText: "Argon・high",
            label: "既有回歸：agy Argon high")

assertBadge("agy --model gemini-4-hydrogen-xhigh",
            expectedTag: "Gemini 4 Hydrogen・xhigh", expectedTab: .gemini, expectedText: "Hydrogen・xhigh",
            label: "既有回歸：agy Hydrogen xhigh")

assertBadge("codex -m gpt-6-luna",
            expectedTag: "Codex gpt-6-luna", expectedTab: .chatgpt, expectedText: "Luna 6",
            label: "既有回歸：codex gpt-6-luna")

assertBadge("copilot -p hi",
            expectedTag: "Copilot", expectedTab: .copilot, expectedText: "",
            label: "既有回歸：copilot")

assertBadge("python3 -m mlx_lm.generate",
            expectedTag: "本機", expectedTab: .local, expectedText: "本機",
            label: "既有回歸：python3 mlx_lm")

// 直接餵 CLI 檔名給 ModelBadge.info（ProcessScan fallback）
let directCases: [(String, ModelTab, String)] = [
    ("agyp", .gemini, "agy"),
    ("dspublic", .deepseek, ""),
    ("dsfree", .deepseek, ""),
    ("dsh-safe", .deepseek, ""),
    ("qwenapi", .qwen, ""),
    ("groqfree", .groq, ""),
    ("gemfree", .gemini, ""),
]
for (raw, expTab, expText) in directCases {
    let info = ModelBadge.info(raw)
    check(info.tab == expTab && info.text == expText,
          "ModelBadge.info(\"\(raw)\") fallback",
          detail: "預期 (\(expTab), \(expText))，實際 (\(String(describing: info.tab)), \(info.text))")
}

// 4. ModelPopover 分頁數不變（維持 5 頁，不含 deepseek／qwen／groq）
let expectedPopoverTabs: [ModelTab] = [.claude, .gemini, .chatgpt, .copilot, .local]
check(ModelTab.popoverCases == expectedPopoverTabs && ModelTab.popoverCases.count == 5,
      "ModelTab.popoverCases 維持原本 5 頁",
      detail: "實際 \(ModelTab.popoverCases)")

let panel = ModelPanelModel()
panel.sections = [
    [ModelRow(id: "opus", title: "Opus 5.5", tip: "", checked: true)],
    [ModelRow(id: "agy:gemini-4-hydrogen-high", title: "Gemini 4 Hydrogen", tip: "", checked: false)],
    [ModelRow(id: "codex:gpt-6-luna", title: "GPT-6 Luna", tip: "", checked: false)],
    [ModelRow(id: "copilot:auto", title: "Auto", tip: "", checked: false)],
    [ModelRow(id: "local:x", title: "LFM2.5", tip: "", checked: false)],
]
check(panel.tabs == expectedPopoverTabs && panel.tabs.count == 5,
      "ModelPanelModel.tabs 維持原本 5 頁（不含新徽章廠商）",
      detail: "實際 \(panel.tabs)")
check(!panel.tabs.contains(.deepseek) && !panel.tabs.contains(.qwen) && !panel.tabs.contains(.groq),
      "ModelPanelModel.tabs 排除 deepseek／qwen／groq")

// 5. 所有 ModelTab（含新徽章廠商）都載入有效圖示，且 monochrome 設定正確
for tab in ModelTab.allCases {
    let img = tab.image
    let ok = img != nil && (img?.size.width ?? 0) > 0 && (img?.size.height ?? 0) > 0
    check(ok, "ModelTab.\(tab.rawValue).image 可載入且尺寸非零",
          detail: "image=\(String(describing: img?.size))")
}
check(!ModelTab.deepseek.monochrome && !ModelTab.qwen.monochrome && ModelTab.groq.monochrome,
      "monochrome 設定：deepseek／qwen 彩色、groq 單色")

// 6. ProcessScan.names 包含 7 個新 CLI
for cli in ["agyp", "dspublic", "dsfree", "dsh-safe", "qwenapi", "groqfree", "gemfree"] {
    check(ProcessScan.names.contains(cli), "ProcessScan.names 包含 \(cli)")
}

// 7. TestHarness --render-models 不展開 badge-only case，且掛上 CODENV_FAKE_RUNNING=badges
let rootPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let harness = (try? String(contentsOfFile: rootPath + "/Sources/Workbench/TestHarness.swift", encoding: .utf8)) ?? ""
check(harness.contains("for t in ModelTab.popoverCases"), "TestHarness --render-models 只遍歷 ModelTab.popoverCases")
check(!harness.contains("for t in ModelTab.allCases"), "TestHarness 不再遍歷 ModelTab.allCases")
check(harness.contains("injectFakeBadgesForTest"), "TestHarness 掛接 CODENV_FAKE_RUNNING=badges → injectFakeBadgesForTest")

print(fails == 0 ? "全部通過（\(total) 項斷言）" : "失敗 \(fails) 項（共 \(total) 項斷言）")
exit(fails == 0 ? 0 : 1)
SWIFT

mkdir -p "$T/modcache"
CLANG_MODULE_CACHE_PATH="$T/modcache" swiftc -O -module-cache-path "$T/modcache" -o "$T/modelbadge-probe" \
    "$T/ModelPopoverSlice.swift" \
    "$T/AgySlice.swift" \
    "$T/ActivitySlice.swift" \
    "$T/ProcessScanSlice.swift" \
    "$T/Stubs.swift" \
    "$T/main.swift"

"$T/modelbadge-probe" "$ROOTDIR"
