// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Workbench",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 終端機模擬（解讀輸出、鍵盤、輸入法）；畫面捲動另外用原生捲動元件
        .package(path: "vendor/SwiftTerm"),   // v1.99.1，加了兩個公開入口（vendor/PATCHES.md）
    ],
    targets: [
        .executableTarget(name: "Workbench", dependencies: ["SwiftTerm"], path: "Sources/Workbench"),
    ]
)
