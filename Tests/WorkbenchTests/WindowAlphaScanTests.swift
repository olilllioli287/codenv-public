import XCTest
@testable import Workbench

final class WindowAlphaScanTests: XCTestCase {

    func testCleanTreeProducesNoFindings() {
        let tree = AlphaScanViewNode(
            className: "NSView",
            alphaValue: 1.0,
            layer: AlphaScanLayerNode(
                className: "CALayer",
                opacity: 1.0,
                presentationOpacity: 1.0,
                animationKeys: [],
                sublayers: [
                    AlphaScanLayerNode(className: "CAShapeLayer", opacity: 1.0),
                ]
            ),
            subviews: [
                AlphaScanViewNode(className: "NSSplitView", alphaValue: 1.0),
                AlphaScanViewNode(className: "TabBar", alphaValue: 1.0, layer: AlphaScanLayerNode(opacity: 1.0)),
            ]
        )

        let result = AlphaScanner.scan(root: tree)
        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.visitedNodes, 4)
        XCTAssertFalse(result.truncatedByNodeLimit)
        XCTAssertFalse(result.truncatedByFindingLimit)
        XCTAssertTrue(AlphaScanFormatter.formatLines(sequence: 1, trigger: "失去焦點", source: "live", result: result).isEmpty)
    }

    func testDetectsViewAlphaLayerOpacityPresentationOpacityAndAnimationKeys() {
        let tree = AlphaScanViewNode(
            className: "ContentView",
            alphaValue: 1.0,
            layer: AlphaScanLayerNode(
                className: "CALayer",
                opacity: 1.0,
                sublayers: [
                    // 殘留的獨立 snapshot layer：model=1.0 但 presentation=0.45
                    AlphaScanLayerNode(
                        className: "CALayer",
                        opacity: 1.0,
                        presentationOpacity: 0.45,
                        animationKeys: ["opacity"]
                    ),
                ]
            ),
            subviews: [
                // 1) view.alphaValue < 1
                AlphaScanViewNode(className: "PaneHostView", alphaValue: 0.65),
                // 2) layer.opacity < 1（view.alphaValue 仍是 1.0）
                AlphaScanViewNode(
                    className: "TabBar",
                    alphaValue: 1.0,
                    layer: AlphaScanLayerNode(className: "CALayer", opacity: 0.5)
                ),
                // 3) model opacity = 1.0，但 presentationOpacity < 1（卡在動畫中間態）
                AlphaScanViewNode(
                    className: "DropOverlay",
                    alphaValue: 1.0,
                    layer: AlphaScanLayerNode(className: "CALayer", opacity: 1.0, presentationOpacity: 0.35)
                ),
                // 4) 所有 alpha/opacity 皆 1.0，但仍有未結束 animationKeys
                AlphaScanViewNode(
                    className: "AnimatedCard",
                    alphaValue: 1.0,
                    layer: AlphaScanLayerNode(
                        className: "CALayer",
                        opacity: 1.0,
                        presentationOpacity: 1.0,
                        animationKeys: ["fadeOut", "position"]
                    )
                ),
                // 5) 隱藏中的 view（isHidden=true, alphaValue=0）：應跳過，不可誤報
                AlphaScanViewNode(
                    className: "HiddenOverlay",
                    isHidden: true,
                    alphaValue: 0.0,
                    subviews: [
                        AlphaScanViewNode(className: "HiddenChild", alphaValue: 0.2),
                    ]
                ),
            ]
        )

        let result = AlphaScanner.scan(root: tree)
        XCTAssertEqual(result.findings.count, 5)

        XCTAssertEqual(result.findings[0].path, "ContentView[0]/PaneHostView[0]")
        XCTAssertEqual(result.findings[0].viewAlpha, 0.65)
        XCTAssertNil(result.findings[0].layerOpacity)

        XCTAssertEqual(result.findings[1].path, "ContentView[0]/TabBar[1]")
        XCTAssertEqual(result.findings[1].viewAlpha, 1.0)
        XCTAssertEqual(result.findings[1].layerOpacity, 0.5)

        XCTAssertEqual(result.findings[2].path, "ContentView[0]/DropOverlay[2]")
        XCTAssertEqual(result.findings[2].layerOpacity, 1.0)
        XCTAssertEqual(result.findings[2].presentationOpacity, 0.35)

        XCTAssertEqual(result.findings[3].path, "ContentView[0]/AnimatedCard[3]")
        XCTAssertEqual(result.findings[3].animationKeys, ["fadeOut", "position"])

        XCTAssertEqual(result.findings[4].path, "ContentView[0]/L:CALayer[0]")
        XCTAssertNil(result.findings[4].viewAlpha)
        XCTAssertEqual(result.findings[4].layerOpacity, 1.0)
        XCTAssertEqual(result.findings[4].presentationOpacity, 0.45)
        XCTAssertEqual(result.findings[4].animationKeys, ["opacity"])

        // 驗證輸出行格式與長度上限
        var captured: [(String, String)] = []
        AlphaScanFormatter.emit(sequence: 3, trigger: "拖曳結束", source: "live", result: result) { cat, msg in
            captured.append((cat, msg))
        }
        XCTAssertEqual(captured.count, 7) // 1 開始 + 5 節點 + 1 結束
        XCTAssertTrue(captured.allSatisfy { $0.0 == "視窗半透明" })
        for (_, line) in captured {
            XCTAssertLessThan(line.count, 380)
        }
        XCTAssertTrue(captured[0].1.hasPrefix("半透明#3 開始 | 觸發=拖曳結束 來源=live 異常數=5 走訪=6 截斷=false"))
        XCTAssertTrue(captured[3].1.contains("半透明#3 節點#3 | 路徑=ContentView[0]/DropOverlay[2] viewAlpha=1.000 layerOpacity=1.000 presOpacity=0.350 anims=none"))
        XCTAssertTrue(captured[5].1.contains("半透明#3 節點#5 | 路徑=ContentView[0]/L:CALayer[0] viewAlpha=n/a layerOpacity=1.000 presOpacity=0.450 anims=opacity"))
        XCTAssertEqual(captured[6].1, "半透明#3 結束 | 節點數=5")
    }

    func testCapsFindingsAt20() {
        let children = (0..<35).map { idx in
            AlphaScanViewNode(className: "CellView", alphaValue: 0.5 + Double(idx) * 0.001)
        }
        let root = AlphaScanViewNode(className: "RootView", subviews: children)

        let result = AlphaScanner.scan(root: root)
        XCTAssertEqual(result.findings.count, 20)
        XCTAssertTrue(result.truncatedByFindingLimit)
        XCTAssertEqual(result.findings.first?.path, "RootView[0]/CellView[0]")
        XCTAssertEqual(result.findings.last?.path, "RootView[0]/CellView[19]")

        let lines = AlphaScanFormatter.formatLines(sequence: 1, trigger: "換螢幕", source: "live", result: result)
        XCTAssertEqual(lines.count, 22) // 開始 + 20 節點 + 結束
        XCTAssertTrue(lines[0].contains("異常數=20") && lines[0].contains("截斷=true"))
        XCTAssertEqual(lines.last, "半透明#1 結束 | 節點數=20")
    }

    func testRespectsMaxVisitedNodesLimit() {
        let children = (0..<120).map { _ in AlphaScanViewNode(className: "LeafView", alphaValue: 1.0) }
        var allChildren = children
        // 把異常節點放在第 121 個（超過 maxVisitedNodes=50），應不觸及且標記截斷
        allChildren.append(AlphaScanViewNode(className: "LateAnomalyView", alphaValue: 0.4))
        let root = AlphaScanViewNode(className: "RootView", subviews: allChildren)

        let result = AlphaScanner.scan(root: root, maxVisitedNodes: 50)
        XCTAssertEqual(result.visitedNodes, 50)
        XCTAssertTrue(result.truncatedByNodeLimit)
        XCTAssertTrue(result.findings.isEmpty)
    }

    func testHiddenSublayerSkippedWhileVisibleNestedSublayerScanned() {
        let root = AlphaScanViewNode(
            className: "RootView",
            layer: AlphaScanLayerNode(
                className: "CALayer",
                sublayers: [
                    AlphaScanLayerNode(
                        className: "HiddenLayer",
                        isHidden: true,
                        opacity: 0.2,
                        sublayers: [AlphaScanLayerNode(className: "InsideHidden", opacity: 0.1)]
                    ),
                    AlphaScanLayerNode(
                        className: "ContainerLayer",
                        opacity: 1.0,
                        sublayers: [AlphaScanLayerNode(className: "ResidualGhostLayer", opacity: 0.42)]
                    ),
                ]
            )
        )
        let result = AlphaScanner.scan(root: root)
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(result.findings[0].path, "RootView[0]/L:ContainerLayer[1]/L:ResidualGhostLayer[0]")
        XCTAssertEqual(result.findings[0].layerOpacity, 0.42)
    }
}
