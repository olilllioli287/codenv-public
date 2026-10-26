# vendor/SwiftTerm 的修改

SwiftTerm v1.99.1（MIT，https://github.com/migueldeicaza/SwiftTerm）原封不動複製進來，只加了兩個公開入口，
都在 `Sources/SwiftTerm/Apple/AppleTerminalView.swift` 的 `withTerminal` 前面：

- `withTerminalPublic(_:)`：在 SwiftTerm 自己的鎖裡讀 Terminal（緩衝區、每格的字和顏色）。
- `cellSizePublic`：一格字的寬高（點，已對齊像素）。

平滑捲動層（Sources/Workbench/SmoothScrollback.swift）靠這兩個畫出跟終端機一模一樣的格子。
更新 SwiftTerm 時：換掉整個資料夾，再把這兩個入口加回去。
