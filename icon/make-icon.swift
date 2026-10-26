// 產生 codenv 的 App 圖示：swift icon/make-icon.swift icon/me.jpg icon/AppIcon-1024.png
// 頭像（使用者的角色）＋一圈 AI 色的光環＋四個小徽章（Claude、GPT、Gemini、VS Code 風格，自己畫的簡化圖形）＋「❯ codenv」
import AppKit

let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}
let claude = hex(0xD97757), gemini = hex(0x7B8CF0), geminiB = hex(0x4E8CF7), vscode = hex(0x1F9CF0), gpt = hex(0x19C39C), accent = hex(0x8F88E8)

// 1. 圓角方形底（Big Sur 的格線：824 見方，四周留 100）＋陰影
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.4).cgColor)
hex(0x14162A).setFill(); tilePath.fill()
ctx.restoreGState()
ctx.saveGState()
tilePath.addClip()
NSGradient(colors: [hex(0x2C2758), hex(0x171A33), hex(0x0D0F1E)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: tile, angle: -90)
// 背景淡淡的程式碼行（編輯器的感覺）
let lines: [(CGFloat, CGFloat, CGFloat)] = [(150, 860, 180), (150, 830, 260), (190, 800, 210), (190, 770, 300), (150, 740, 150),
                                            (640, 300, 160), (680, 270, 200), (640, 240, 120)]
for (x, y, w) in lines {
    hex(0xFFFFFF, 0.045).setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: 14), xRadius: 7, yRadius: 7).fill()
}
ctx.restoreGState()

// 2. 頭像：原圖裁臉（原圖 1024×768，臉大約在左上原點 (470, 255)），放進圓裡
let center = NSPoint(x: 512, y: 572)
let r: CGFloat = 228
let crop = NSRect(x: 225, y: 768 - 520, width: 500, height: 500)   // 換成左下原點
ctx.saveGState()
NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).addClip()
hex(0xEFEDF2).setFill(); NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r).fill()
src.draw(in: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r), from: crop, operation: .sourceOver, fraction: 1)
ctx.restoreGState()

// 3. 光環：一圈分段畫的漸層（Claude 橘 → Gemini 藍紫 → VS Code 藍 → GPT 綠 → 回到橘）
let ringR = r + 20
let stops = [claude, gemini, vscode, gpt, claude]
let segs = 240
for i in 0..<segs {
    let t = CGFloat(i) / CGFloat(segs)
    let f = t * CGFloat(stops.count - 1)
    let k = min(Int(f), stops.count - 2)
    let c = stops[k].blended(withFraction: f - CGFloat(k), of: stops[k + 1])!
    let a0 = 90 - t * 360, a1 = 90 - (t + 1.2 / CGFloat(segs)) * 360
    let p = NSBezierPath()
    p.appendArc(withCenter: center, radius: ringR, startAngle: a0, endAngle: a1, clockwise: true)
    p.lineWidth = 20
    c.setStroke(); p.stroke()
}

// 4. 徽章
func badge(at deg: CGFloat, fill: NSColor, _ draw: (NSPoint, CGFloat) -> Void) {
    let rad = deg * .pi / 180
    let c = NSPoint(x: center.x + ringR * cos(rad), y: center.y + ringR * sin(rad))
    let br: CGFloat = 66
    let o = NSBezierPath(ovalIn: NSRect(x: c.x - br, y: c.y - br, width: 2 * br, height: 2 * br))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    fill.setFill(); o.fill()
    ctx.restoreGState()
    o.lineWidth = 7; hex(0x0D0F1E).setStroke(); o.stroke()
    draw(c, br)
}
// Claude：放射的星芒（長短不一的圓頭線）
badge(at: 45, fill: hex(0x1E1A2E)) { c, br in
    let n = 11
    for i in 0..<n {
        let a = CGFloat(i) / CGFloat(n) * 2 * .pi + 0.2
        let len = br * (i % 2 == 0 ? 0.62 : 0.48)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x + cos(a) * br * 0.12, y: c.y + sin(a) * br * 0.12))
        p.line(to: NSPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len))
        p.lineWidth = 11; p.lineCapStyle = .round
        claude.setStroke(); p.stroke()
    }
}
// GPT：六片圓角花瓣排成的花結（外框線）
badge(at: 135, fill: hex(0xF4F5F7)) { c, br in
    for i in 0..<6 {
        let a = CGFloat(i) * 60
        let t = NSAffineTransform()
        t.translateX(by: c.x, yBy: c.y); t.rotate(byDegrees: a)
        let petal = NSBezierPath(roundedRect: NSRect(x: -br * 0.16, y: br * 0.02, width: br * 0.32, height: br * 0.55), xRadius: br * 0.16, yRadius: br * 0.16)
        petal.transform(using: t as AffineTransform)
        petal.lineWidth = 7; hex(0x111111).setStroke(); petal.stroke()
    }
}
// Gemini：四角星（邊往內彎），藍到紫漸層
badge(at: -45, fill: hex(0x1A1D33)) { c, br in
    let s = br * 0.66
    let p = NSBezierPath()
    p.move(to: NSPoint(x: c.x, y: c.y + s))
    p.curve(to: NSPoint(x: c.x + s, y: c.y), controlPoint1: NSPoint(x: c.x + s * 0.12, y: c.y + s * 0.12), controlPoint2: NSPoint(x: c.x + s * 0.12, y: c.y + s * 0.12))
    p.curve(to: NSPoint(x: c.x, y: c.y - s), controlPoint1: NSPoint(x: c.x + s * 0.12, y: c.y - s * 0.12), controlPoint2: NSPoint(x: c.x + s * 0.12, y: c.y - s * 0.12))
    p.curve(to: NSPoint(x: c.x - s, y: c.y), controlPoint1: NSPoint(x: c.x - s * 0.12, y: c.y - s * 0.12), controlPoint2: NSPoint(x: c.x - s * 0.12, y: c.y - s * 0.12))
    p.curve(to: NSPoint(x: c.x, y: c.y + s), controlPoint1: NSPoint(x: c.x - s * 0.12, y: c.y + s * 0.12), controlPoint2: NSPoint(x: c.x - s * 0.12, y: c.y + s * 0.12))
    p.close()
    ctx.saveGState(); p.addClip()
    NSGradient(colors: [geminiB, hex(0x9B72CB), hex(0xD96570)], atLocations: [0, 0.6, 1], colorSpace: .sRGB)!
        .draw(in: NSRect(x: c.x - s, y: c.y - s, width: 2 * s, height: 2 * s), angle: -45)
    ctx.restoreGState()
}
// VS Code：藍底白色 </>
badge(at: 225, fill: hex(0x0B6FC2)) { c, br in
    let w: CGFloat = 10
    let l = NSBezierPath(); l.move(to: NSPoint(x: c.x - br * 0.22, y: c.y + br * 0.3)); l.line(to: NSPoint(x: c.x - br * 0.52, y: c.y)); l.line(to: NSPoint(x: c.x - br * 0.22, y: c.y - br * 0.3))
    let rr = NSBezierPath(); rr.move(to: NSPoint(x: c.x + br * 0.22, y: c.y + br * 0.3)); rr.line(to: NSPoint(x: c.x + br * 0.52, y: c.y)); rr.line(to: NSPoint(x: c.x + br * 0.22, y: c.y - br * 0.3))
    let sl = NSBezierPath(); sl.move(to: NSPoint(x: c.x + br * 0.1, y: c.y + br * 0.4)); sl.line(to: NSPoint(x: c.x - br * 0.1, y: c.y - br * 0.4))
    for p in [l, rr, sl] { p.lineWidth = w; p.lineCapStyle = .round; p.lineJoinStyle = .round; NSColor.white.setStroke(); p.stroke() }
}

// 5. 「❯ codenv」
let font = NSFont.monospacedSystemFont(ofSize: 84, weight: .bold)
let text = NSMutableAttributedString(string: "❯", attributes: [.font: font, .foregroundColor: accent, .kern: 22])
text.append(NSAttributedString(string: "codenv", attributes: [.font: font, .foregroundColor: NSColor.white]))
let ts = text.size()
text.draw(at: NSPoint(x: 512 - ts.width / 2, y: 168))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("ok")
