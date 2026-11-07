import AppKit
import CoreGraphics

// 嵌在右欄桌寵框右半的打字桌寵（外面的桌寵由他自己結束）。
// 素材、姿勢對應、打字下壓都從外面的打字桌寵 App 搬來；左半是 PetTimers（pet-progress 進度），這裡不畫頭上的圈。
// 打字事件：有「輸入監控」權限時用 CGEventTap（listenOnly）聽全系統；沒有就只聽 codenv 自己收到的按鍵，不反覆跳權限視窗。
// 素材只放私人版（public/exclude.txt 排除 Resources/pet）。

enum PetEmbedPrefs {
    static let changed = Notification.Name("codenv.petEmbedChanged")
    static let characters: [(id: String, name: String)] = [("zumi", "租咪"), ("aji", "阿基"), ("alei", "阿雷"), ("xiaosheng", "小生")]
    static let pressNames = ["關", "弱", "中", "強"]
    private static var d: UserDefaults { appDefaults }
    /// 外面的桌寵目前的設定（唯讀）：第一次用時當預設
    private static var external: UserDefaults? { UserDefaults(suiteName: "com.local.desktoppet") }

    static var enabled: Bool {
        get { d.object(forKey: "petEmbedOn") as? Bool ?? true }
        set { d.set(newValue, forKey: "petEmbedOn"); NotificationCenter.default.post(name: changed, object: nil) }
    }
    static var character: String {
        get {
            let id = d.string(forKey: "petEmbedCharacter") ?? external?.string(forKey: "character") ?? "zumi"
            return characters.contains { $0.id == id } ? id : "zumi"
        }
        set { d.set(newValue, forKey: "petEmbedCharacter"); NotificationCenter.default.post(name: changed, object: nil) }
    }
    /// 打字下壓：0 關、1 弱 3 點、2 中 5 點、3 強 8 點
    static var pressLevel: Int {
        get { min(3, max(0, d.object(forKey: "petEmbedPress") as? Int ?? external?.object(forKey: "pressLevel") as? Int ?? 2)) }
        set { d.set(min(3, max(0, newValue)), forKey: "petEmbedPress"); NotificationCenter.default.post(name: changed, object: nil) }
    }
}

enum PetPose: String, CaseIterable {
    case base, lefthand, righthand, surprise, enter, up, down, left, right, dots, question
}

enum PetKeyMap {
    static let leftHandKeys: Set<Int64> = [
        50, 18, 19, 20, 21, 23, 48, 12, 13, 14, 15, 17, 57, 0, 1, 2, 3, 5, 6, 7, 8, 9, 11,
        53, 122, 120, 99, 118, 96, 59, 58, 55, 56,
    ]
    static let modifierBits: [Int64: UInt64] = [
        59: 0x0001, 62: 0x2000, 56: 0x0002, 60: 0x0004, 55: 0x0008, 54: 0x0010, 58: 0x0020, 61: 0x0040,
        63: CGEventFlags.maskSecondaryFn.rawValue,
    ]
    static func isModifierPress(keyCode: Int64, flags: UInt64) -> Bool {
        guard let bit = modifierBits[keyCode] else { return false }
        return flags & bit != 0
    }
    static func pose(keyCode: Int64, shift: Bool) -> (PetPose, TimeInterval) {
        switch keyCode {
        case 51, 117: return (.surprise, 0.5)
        case 36, 76: return (.enter, 0.35)
        case 126: return (.up, 0.3)
        case 125: return (.down, 0.3)
        case 123: return (.left, 0.3)
        case 124: return (.right, 0.3)
        case 65: return (.dots, 0.5)
        case 47 where !shift: return (.dots, 0.5)
        case 44 where shift: return (.question, 0.6)
        default: return (leftHandKeys.contains(keyCode) ? .lefthand : .righthand, 0.15)
        }
    }
}

/// 打字時往下壓（不回彈，只往目標逼近）：同 desktop-pet/Bounce.swift
struct PetTypingPress {
    static let depths: [CGFloat] = [0, 3, 5, 8]
    static let downTime = 0.025
    static let upTime = 0.15
    static let hold = 0.1
    private(set) var offset: CGFloat = 0
    private var target: CGFloat = 0
    private var sinceKey: Double = .infinity
    var isMoving: Bool { offset != 0 || target != 0 }
    mutating func press(level: Int) {
        let d = Self.depths[min(max(level, 0), Self.depths.count - 1)]
        guard d > 0 else { return }
        target = d; sinceKey = 0
    }
    mutating func step(_ dt: Double) {
        guard isMoving, dt > 0 else { return }
        let dt = min(dt, 0.25)
        sinceKey += dt
        if sinceKey >= Self.hold { target = 0 }
        let tau = target > offset ? Self.downTime : Self.upTime
        offset = target + (offset - target) * CGFloat(exp(-dt / tau))
        if target == 0 && offset < 0.05 { offset = 0 }
    }
}

/// 一個角色的全部姿勢，裁掉共同的透明邊（換圖時角色不會跳動）
final class PetSprites {
    private(set) var images: [PetPose: CGImage] = [:]
    private(set) var aspect: CGFloat = 1
    private static var cache: [String: PetSprites] = [:]
    /// 有沒有任何角色圖（公版不帶素材：桌寵就不畫、設定頁也不顯示）
    static var available: Bool = PetEmbedPrefs.characters.contains { !load($0.id).images.isEmpty }
    static func load(_ id: String) -> PetSprites { if let c = cache[id] { return c }; let s = PetSprites(id); cache[id] = s; return s }

    private init(_ id: String) {
        var raw: [PetPose: CGImage] = [:]
        for pose in PetPose.allCases {
            guard let url = Bundle.main.url(forResource: pose.rawValue, withExtension: "png", subdirectory: "pet/\(id)")
                    ?? Self.sourceURL(id, pose),
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            raw[pose] = img
        }
        var box = CGRect.null
        for img in raw.values { box = box.union(Self.opaqueBounds(img)) }
        if box.isNull { box = CGRect(x: 0, y: 0, width: 1, height: 1) }
        for (pose, img) in raw { images[pose] = img.cropping(to: box) ?? img }
        aspect = box.width / box.height
    }

    /// 直接跑 .build 裡的執行檔時：用原始碼旁邊的素材
    private static func sourceURL(_ id: String, _ pose: PetPose) -> URL? {
        let u = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/pet/\(id)/\(pose.rawValue).png")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private static func opaqueBounds(_ img: CGImage) -> CGRect {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              true else { return CGRect(x: 0, y: 0, width: w, height: h) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return CGRect(x: 0, y: 0, width: w, height: h) }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where data[(y * w + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= 0 else { return .null }
        // ctx 的 y 軸朝上，CGImage.cropping 的 y 軸朝下
        return CGRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

/// 按鍵來源：有輸入監控權限 → CGEventTap 全系統；沒有 → 只有 codenv 自己收到的（KeyStatsApp.sendEvent 轉進來）
final class PetKeys {
    static let shared = PetKeys()
    var onKey: ((Int64, Bool) -> Void)?          // keyCode、有沒有按著 shift
    private var tap: CFMachPort?
    private var retry: Timer?
    var globalActive: Bool { tap != nil }
    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    /// 不會跳權限視窗：沒權限就不建 tap，之後每 5 秒靜靜地看一次（使用者授權後自動接上）
    func start() {
        guard retry == nil else { return }
        tryStartTap()
        retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tryStartTap() }
    }

    private func tryStartTap() {
        guard tap == nil, Self.hasPermission, !CommandLine.arguments.contains("--no-pet-tap") else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.flagsChanged.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: { _, type, event, ref in
            let k = Unmanaged<PetKeys>.fromOpaque(ref!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = k.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else if type == .keyDown {
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, code != 179 { k.onKey?(code, event.flags.contains(.maskShift)) }
            } else if type == .flagsChanged {
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                if PetKeyMap.isModifierPress(keyCode: code, flags: event.flags.rawValue) { k.onKey?(code, event.flags.contains(.maskShift)) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// KeyStatsApp.sendEvent 轉進來：全系統已經在聽就不重複
    func localEvent(_ e: NSEvent) {
        guard !globalActive else { return }
        if e.type == .keyDown, !e.isARepeat { onKey?(Int64(e.keyCode), e.modifierFlags.contains(.shift)) }
        else if e.type == .flagsChanged, PetKeyMap.isModifierPress(keyCode: Int64(e.keyCode), flags: UInt64(e.modifierFlags.rawValue)) {
            onKey?(Int64(e.keyCode), e.modifierFlags.contains(.shift))
        }
    }

    static func openPrivacySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(u) }
    }
}

/// 說話泡泡（pet-say：com.local.desktoppet.say）：倒數預告或提醒
final class PetBubbleView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private var hideWork: DispatchWorkItem?
    private var ack = PetNoticeAck()
    private(set) var isNotice = false
    var text: String { label.stringValue }
    static let tail: CGFloat = 10, pad: CGFloat = 12
    var tailX: CGFloat = 0
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .black
        label.preferredMaxLayoutWidth = 200
        addSubview(label)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// seconds ≥ 0：倒數預告；< 0：提醒（停在那裡，90 秒或使用者停手後按一下鍵才收）
    func say(_ message: String, seconds: Int, place: @escaping (NSSize) -> NSRect) {
        timer?.invalidate(); hideWork?.cancel()
        isNotice = false
        guard !message.isEmpty else { hide(); return }
        let show = { [weak self] (t: String) in
            guard let self else { return }
            self.label.stringValue = t
            let s = self.label.fittingSize
            let size = NSSize(width: ceil(s.width) + Self.pad * 2, height: ceil(s.height) + Self.pad * 2 + Self.tail)
            self.frame = place(size)
            self.label.frame = NSRect(x: Self.pad, y: Self.pad, width: ceil(s.width), height: ceil(s.height))
            self.isHidden = false
            self.needsDisplay = true
        }
        if seconds < 0 {
            isNotice = true; ack.shown(); show(message)
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: w)
            return
        }
        var remaining = seconds
        let update = { show(remaining > 0 ? "\(remaining) 秒後\n\(message)" : "現在：\(message)") }
        update()
        if remaining == 0 { finishSoon(); return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            remaining -= 1; update()
            if remaining <= 0 { t.invalidate(); self?.finishSoon() }
        }
    }

    private func finishSoon() {
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }

    func keyPressed() {
        guard ack.key(), isNotice else { return }
        isNotice = false; hideWork?.cancel(); hide()
    }

    func hide() { timer?.invalidate(); isHidden = true }

    override func draw(_ dirtyRect: NSRect) {
        let t = Self.tail
        let body = NSRect(x: 1, y: t + 1, width: bounds.width - 2, height: bounds.height - t - 2)
        let path = NSBezierPath(roundedRect: body, xRadius: 12, yRadius: 12)
        let x = min(max(tailX, body.minX + 18), body.maxX - 18)
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: x - 8, y: body.minY + 1)); tri.line(to: NSPoint(x: x, y: 1)); tri.line(to: NSPoint(x: x + 8, y: body.minY + 1))
        tri.close(); path.append(tri)
        NSColor(white: 1, alpha: 0.97).setFill(); path.fill()
        NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.2, alpha: 1).setStroke()
        path.lineWidth = 2; path.stroke()
    }
}

/// 提醒要停手 1 秒後再按鍵才算看到（同 desktop-pet/NoticeAck.swift）
struct PetNoticeAck {
    static let quiet: TimeInterval = 1
    private var shownAt = Date.distantPast
    private var lastKeyAt = Date.distantPast
    mutating func shown(at now: Date = Date()) { shownAt = now }
    mutating func key(at now: Date = Date()) -> Bool {
        defer { lastKeyAt = now }
        return now.timeIntervalSince(shownAt) >= Self.quiet && now.timeIntervalSince(lastKeyAt) >= Self.quiet
    }
}

/// 畫在桌寵框右半的桌寵本體
final class PetEmbedView: NSView {
    private let spriteLayer = CALayer()
    private var sprites = PetSprites.load(PetEmbedPrefs.character)
    private(set) var pose: PetPose = .base
    private var revert: DispatchWorkItem?
    private var press = PetTypingPress()
    private var pressTimer: Timer?
    private var lastTick: CFTimeInterval = 0
    let bubble = PetBubbleView()
    private var observers: [NSObjectProtocol] = []
    static let bounceRoom: CGFloat = 8
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var pressOffset: CGFloat { press.offset }
    /// 像素畫的一個像素在畫面上是幾點（素材每 10×10 圖點是一格像素）；不到 1 點就用 1 點
    var cellPoints: CGFloat {
        let imgH = CGFloat(sprites.images[.base]?.height ?? 0)
        guard imgH > 0, spriteLayer.frame.height > 0 else { return 1 }
        return max(1, 10 * spriteLayer.frame.height / imgH)
    }
    /// 桌寵靜止時的底邊：原本離框底 bounceRoom（留給下壓），要往下貼近框底
    /// 照他畫的紅綠線在截圖上量（終端機按鈕 34 點＝66 像素當比例尺）共往下 9.3 點；下壓時最底下會被框底切掉，可以接受
    static let restDrop: CGFloat = 9.3
    var restY: CGFloat { Self.bounceRoom - Self.restDrop }
    var spriteFrame: NSRect { spriteLayer.frame }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(spriteLayer)
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .trilinear
        spriteLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull()]
        show(.base)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0); DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
        guard window != nil else { return }
        PetKeys.shared.onKey = { [weak self] code, shift in self?.typed(code, shift: shift) }
        PetKeys.shared.start()
        observers.append(NotificationCenter.default.addObserver(forName: PetEmbedPrefs.changed, object: nil, queue: .main) { [weak self] _ in self?.reload() })
        // pet-say：codenv 沒在前景也照樣在框裡畫（不另外做桌面通知）
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.local.desktoppet.say"), object: nil, queue: .main) { [weak self] note in
            let text = note.userInfo?["text"] as? String ?? ""
            let secs = (note.userInfo?["seconds"] as? NSNumber)?.intValue ?? 0
            self?.say(text, seconds: secs)
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.local.hub.action"), object: Bundle.main.bundleIdentifier, queue: .main) { note in
            guard let a = note.userInfo?["action"] as? String else { return }
            if a.hasPrefix("pet.character."), PetEmbedPrefs.characters.contains(where: { $0.id == String(a.dropFirst(14)) }) { PetEmbedPrefs.character = String(a.dropFirst(14)) }
            else if a.hasPrefix("pet.press."), let n = Int(a.dropFirst(10)) { PetEmbedPrefs.pressLevel = n }
            else if a == "pet.toggle" { PetEmbedPrefs.enabled.toggle() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.local.hub.reload"), object: Bundle.main.bundleIdentifier, queue: .main) { [weak self] _ in self?.reload() })
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0); DistributedNotificationCenter.default().removeObserver($0) } }

    func reload() { sprites = PetSprites.load(PetEmbedPrefs.character); show(pose); needsLayout = true; superview?.needsLayout = true }

    override func layout() {
        super.layout()
        let h = max(0, bounds.height - Self.bounceRoom - 4)
        let w = min(bounds.width - 8, h * sprites.aspect)
        let hh = sprites.aspect > 0 ? w / sprites.aspect : h
        spriteLayer.frame = NSRect(x: bounds.width - w - 4, y: 0, width: w, height: hh)
        spriteLayer.frame.origin.y = restY - press.offset
        spriteLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    func show(_ p: PetPose) {
        pose = p
        spriteLayer.contents = sprites.images[p] ?? sprites.images[.base]
    }

    func typed(_ code: Int64, shift: Bool) {
        bubble.keyPressed()
        guard PetEmbedPrefs.enabled, window != nil else { return }
        let (p, secs) = PetKeyMap.pose(keyCode: code, shift: shift)
        show(p)
        revert?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.show(.base) }
        revert = w
        DispatchQueue.main.asyncAfter(deadline: .now() + secs, execute: w)
        press.press(level: PetEmbedPrefs.pressLevel)
        startPressTimer()
    }

    private func startPressTimer() {
        guard pressTimer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let now = CACurrentMediaTime()
            self.press.step(now - self.lastTick); self.lastTick = now
            var f = self.spriteLayer.frame; f.origin.y = self.restY - self.press.offset
            CATransaction.begin(); CATransaction.setDisableActions(true); self.spriteLayer.frame = f; CATransaction.commit()
            if !self.press.isMoving { t.invalidate(); self.pressTimer = nil }
        }
        t.tolerance = 0
        pressTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    func say(_ text: String, seconds: Int) {
        guard let host = bubble.superview ?? superview?.superview else { return }
        if bubble.superview == nil { host.addSubview(bubble) }
        bubble.say(text, seconds: seconds) { [weak self, weak host] size in
            guard let self, let host else { return .zero }
            let r = self.convert(self.spriteLayer.frame, to: host)
            let w = min(size.width, host.bounds.width - 8)
            let x = min(max(r.midX - w / 2, 4), host.bounds.width - w - 4)
            self.bubble.tailX = r.midX - x
            return NSRect(x: x, y: min(r.maxY + 2, max(0, host.bounds.height - size.height)), width: w, height: size.height)
        }
    }
}

import SwiftUI

/// 設定頁的「桌寵」區：開關、角色、打字下壓、輸入監控狀態
struct PetEmbedSettings: View {
    @State private var enabled = PetEmbedPrefs.enabled
    @State private var character = PetEmbedPrefs.character
    @State private var press = PetEmbedPrefs.pressLevel
    @State private var global = PetKeys.shared.globalActive
    @State private var allowed = PetKeys.hasPermission
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        Toggle(L("在右欄下面顯示桌寵（左邊是 AI 工作進度）"), isOn: $enabled).onChange(of: enabled) { _, v in PetEmbedPrefs.enabled = v }
        Picker(L("角色"), selection: $character) {
            ForEach(PetEmbedPrefs.characters, id: \.id) { Text($0.name).tag($0.id) }
        }.onChange(of: character) { _, v in PetEmbedPrefs.character = v }
        Picker(L("打字下壓"), selection: $press) {
            ForEach(Array([L("關"), L("弱"), L("中"), L("強")].enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
        }.onChange(of: press) { _, v in PetEmbedPrefs.pressLevel = v }
        HStack {
            Text(global ? L("按鍵：全系統（已授權輸入監控）") : L("按鍵：只有在 codenv 裡打字會動；要全系統都動，請授權「輸入監控」給 codenv"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !global {
                Button(L("打開輸入監控設定")) { PetKeys.openPrivacySettings() }
            }
        }
        .onReceive(tick) { _ in global = PetKeys.shared.globalActive; allowed = PetKeys.hasPermission }
    }
}
