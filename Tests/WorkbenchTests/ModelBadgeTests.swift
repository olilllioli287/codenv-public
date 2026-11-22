import XCTest
@testable import Workbench

final class ModelBadgeTests: XCTestCase {
    private func assertCommand(_ cmd: String, tag expectedTag: String, tab expectedTab: ModelTab?, text expectedText: String, file: StaticString = #filePath, line: UInt = #line) {
        let tag = SessionActivity.externalModel(in: cmd)
        XCTAssertEqual(tag, expectedTag, "externalModel(\(cmd))", file: file, line: line)
        if let tag {
            let info = ModelBadge.info(tag)
            XCTAssertEqual(info.tab, expectedTab, "ModelBadge.info(\(tag)).tab", file: file, line: line)
            XCTAssertEqual(info.text, expectedText, "ModelBadge.info(\(tag)).text", file: file, line: line)
        }
    }

    func testNewCliCommandsAndBadges() {
        assertCommand("agyp --model gemini-4-neon-xhigh", tag: "Gemini 4 Neon・xhigh", tab: .gemini, text: "Neon・xhigh")
        assertCommand("dspublic --public -m deepseek-flash", tag: "DeepSeek deepseek-flash", tab: .deepseek, text: "Flash")
        assertCommand("qwenapi --public", tag: "Qwen", tab: .qwen, text: "")
        assertCommand("qwenapi --public -m qwen4-max", tag: "Qwen qwen4-max", tab: .qwen, text: "Qwen4 Max")
        assertCommand("dsh-safe \"x\"", tag: "DeepSeek", tab: .deepseek, text: "")
        assertCommand("dsfree \"x\"", tag: "DeepSeek", tab: .deepseek, text: "")
        assertCommand("groqfree", tag: "Groq", tab: .groq, text: "")
        assertCommand("groqfree -m llama-3.3-70b", tag: "Groq llama-3.3-70b", tab: .groq, text: "Llama 3.3 70b")
        assertCommand("gemfree", tag: "Gemini", tab: .gemini, text: "")
        assertCommand("gemfree -m gemini-3.8-flash", tag: "Gemini 3.8 Flash", tab: .gemini, text: "3.8 Flash")
        assertCommand("echo x | dspublic --public", tag: "DeepSeek", tab: .deepseek, text: "")
        assertCommand("cat diff.txt | dspublic --public -m deepseek-flash", tag: "DeepSeek deepseek-flash", tab: .deepseek, text: "Flash")
        assertCommand("AGYP_ACCOUNT=agy2 agyp --model gemini-4-neon-xhigh -p hi", tag: "Gemini 4 Neon・xhigh", tab: .gemini, text: "Neon・xhigh")
        assertCommand("agyp --model claude-sonnet-5-5-high", tag: "Claude Sonnet 5.5・high", tab: .claude, text: "Sonnet 5.5・high")
        assertCommand("agyp -p hi", tag: "agy", tab: .gemini, text: "agy")
    }

    func testMentionedOnlyCommandsAreIgnored() {
        XCTAssertNil(SessionActivity.externalModel(in: "grep agyp"))
        XCTAssertNil(SessionActivity.externalModel(in: "grep agyp file.txt"))
        XCTAssertNil(SessionActivity.externalModel(in: "which dspublic"))
        XCTAssertNil(SessionActivity.externalModel(in: "echo qwenapi groqfree gemfree"))
    }

    func testExistingCommandsRegression() {
        assertCommand("agy --model gemini-4-argon-high", tag: "Gemini 4 Argon・high", tab: .gemini, text: "Argon・high")
        assertCommand("agy --model gemini-4-hydrogen-xhigh", tag: "Gemini 4 Hydrogen・xhigh", tab: .gemini, text: "Hydrogen・xhigh")
        assertCommand("codex -m gpt-6-luna", tag: "Codex gpt-6-luna", tab: .chatgpt, text: "Luna 6")
        assertCommand("copilot -p hi", tag: "Copilot", tab: .copilot, text: "")
        assertCommand("python3 -m mlx_lm.generate", tag: L("本機"), tab: .local, text: L("本機"))
    }

    func testModelPopoverTabsUnchanged() {
        let expected: [ModelTab] = [.claude, .gemini, .chatgpt, .copilot, .local]
        XCTAssertEqual(ModelTab.popoverCases, expected)
        XCTAssertEqual(ModelTab.popoverCases.count, 5)

        let model = ModelPanelModel()
        model.sections = [
            [ModelRow(id: "opus", title: "Opus 5.5", tip: "", checked: true)],
            [ModelRow(id: "agy:gemini-4-hydrogen-high", title: "Gemini 4 Hydrogen", tip: "", checked: false)],
            [ModelRow(id: "codex:gpt-6-luna", title: "GPT-6 Luna", tip: "", checked: false)],
            [ModelRow(id: "copilot:auto", title: "Auto", tip: "", checked: false)],
            [ModelRow(id: "local:x", title: "LFM2.5", tip: "", checked: false)],
        ]
        XCTAssertEqual(model.tabs, expected)
        XCTAssertEqual(model.tabs.count, 5)
    }

    func testAllModelTabImagesLoad() {
        for tab in ModelTab.allCases {
            let img = tab.image
            XCTAssertNotNil(img, "ModelTab.\(tab.rawValue).image should load")
            XCTAssertGreaterThan(img?.size.width ?? 0, 0)
            XCTAssertGreaterThan(img?.size.height ?? 0, 0)
        }
    }

    func testInjectFakeBadgesForTestPopulatesExpectedBadges() {
        let activity = SessionActivity()
        let id = UUID()
        activity.injectFakeBadgesForTest(id)
        let items = activity.running(id)
        XCTAssertEqual(items.count, 7)
        let tabs = items.compactMap { $0.tag.flatMap { ModelBadge.info($0).tab } }
        XCTAssertEqual(tabs, [.gemini, .deepseek, .qwen, .deepseek, .groq, .gemini, .deepseek])
    }
}
