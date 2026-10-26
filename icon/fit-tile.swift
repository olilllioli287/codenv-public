// 把 AI 畫的「圓角方形放在米白底上」的圖，切成 macOS 圖示：找出方塊範圍、外面變透明、照 Big Sur 格線放（824 見方、四周留 100）、補陰影
// swift icon/fit-tile.swift 原圖.png 輸出-1024.png
import AppKit
let a = CommandLine.arguments
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: a[1])))!
let W = src.pixelsWide, H = src.pixelsHigh
// 方塊範圍：亮度明顯比底色暗的像素（底色是米白）
var minX = W, minY = H, maxX = 0, maxY = 0
for y in stride(from: 0, to: H, by: 2) {
    for x in stride(from: 0, to: W, by: 2) {
        guard let c = src.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        if c.brightnessComponent < 0.6 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
    }
}
let tile = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)   // 左上原點
print("tile", tile)
let S: CGFloat = 1024
let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
let ctx = NSGraphicsContext.current!.cgContext
let dst = NSRect(x: 100, y: 100, width: 824, height: 824)
let r: CGFloat = 185
let path = NSBezierPath(roundedRect: dst, xRadius: r, yRadius: r)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.4).cgColor)
NSColor(srgbRed: 0.1, green: 0.1, blue: 0.25, alpha: 1).setFill(); path.fill()
ctx.restoreGState()
path.addClip()
// 原圖方塊（往內縮一點點，切掉 AI 畫的邊緣陰影和反光）
let inset: CGFloat = tile.width * 0.012
let from = NSRect(x: tile.minX + inset, y: CGFloat(H) - tile.maxY + inset, width: tile.width - 2 * inset, height: tile.height - 2 * inset)
let img = NSImage(size: NSSize(width: W, height: H)); img.addRepresentation(src)
img.draw(in: dst, from: from, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
print("ok")
