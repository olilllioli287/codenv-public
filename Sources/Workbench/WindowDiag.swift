import AppKit
import CoreGraphics
import QuartzCore

// 視窗透明／跨螢幕診斷（支援多視窗，純唯讀觀察，寫進 EventLog；不修改視窗或 layer 狀態）
@MainActor
enum WindowDiag {
    private enum ScreenIdentity: Equatable {
        case display(CGDirectDisplayID)
        case index(Int)
        case none
    }

    @MainActor
    private final class WindowState {
        let serial: Int
        weak var window: NSWindow?
        var tokens: [NSObjectProtocol] = []
        var screenBackingFollowUpWork: DispatchWorkItem?
        var moveDebounceWork: DispatchWorkItem?
        var anomalyWork1s: DispatchWorkItem?
        var anomalyWork5s: DispatchWorkItem?
        var anomalyFollowUpActive = false
        var lastLoggedScreen: ScreenIdentity?
        var lastLoggedWindowNumber: Int?
        var lastLoggedTimeByEvent: [String: TimeInterval] = [:]

        init(serial: Int, window: NSWindow) {
            self.serial = serial
            self.window = window
        }

        func invalidate() {
            let nc = NotificationCenter.default
            for t in tokens {
                nc.removeObserver(t)
            }
            tokens.removeAll()
            screenBackingFollowUpWork?.cancel()
            screenBackingFollowUpWork = nil
            moveDebounceWork?.cancel()
            moveDebounceWork = nil
            anomalyWork1s?.cancel()
            anomalyWork1s = nil
            anomalyWork5s?.cancel()
            anomalyWork5s = nil
            anomalyFollowUpActive = false
            lastLoggedScreen = nil
            lastLoggedWindowNumber = nil
            lastLoggedTimeByEvent.removeAll()
        }
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")
    private static let eventDedupeInterval: TimeInterval = 0.1
    private static let rateLimitWindow: TimeInterval = 60.0
    private static let maxLinesPerMinute = 60

    private static let recoverableAnomalies: Set<String> = [
        "alpha-低",
        "內容層透明",
        "背景透明",
        "內容view-alpha-低",
    ]

    private static let allowedColorSpaces: [String: String] = [
        "srgb": "sRGB",
        "displayp3": "DisplayP3",
        "genericrgb": "GenericRGB",
        "extendedsrgb": "ExtendedSRGB",
        "extendedlinearsrgb": "ExtendedLinearSRGB",
        "genericgray": "GenericGray",
    ]

    private static var states: [ObjectIdentifier: WindowState] = [:]
    private static var nextWindowSerial = 1
    private static var screenParamsObserverRegistered = false
    private static var screenParamsObserverToken: NSObjectProtocol?
    private static var loggedTimestamps: [TimeInterval] = []

    // 視窗卡住（非作用中 Space／WS 非 onscreen）輕量偵測器（只在主視窗與事件變化時運作，不設常駐輪詢）
    private static weak var monitoredMainWindow: NSWindow?
    private static var stuckDetector = WindowStuckDetector()
    private static var stuckCheckWork: DispatchWorkItem?
    private static var stuckCheckDeadline: TimeInterval?
    private static var stuckObserverTokens: [NSObjectProtocol] = []
    private static var workspaceObserverToken: NSObjectProtocol?
    private static var injectedOverride: WindowDiagOverride?

    // 第 2 輪 A.3：焦點／前景化呼叫來源（退路版：只掛通知、絕不做 method swizzling）
    private static var focusSourceObserverTokens: [NSObjectProtocol] = []
    private static var focusSourceRateLimiter = WindowDiagRateLimiter()

    // 第 2 輪 B：主視窗半透明掃描（只在失去焦點／換螢幕／拖曳結束觸發，含 debounce 與 4000 節點上限，純唯讀）
    private static var alphaScanObserverTokens: [NSObjectProtocol] = []
    private static var alphaScanMouseMonitor: Any?
    private static var alphaScanSawMouseDrag = false
    private static var alphaScanDebounceByTrigger: [String: DispatchWorkItem] = [:]
    private static var alphaScanSequence = 0

    // 第 2 輪 C：點 Dock 救援第一階段（只在異常時跑 3 步，含 60s 冷卻、進行中防重入、每次啟動 5 次上限）
    private static var rescueCoordinator = WindowRescueCoordinator()

    /// 在視窗建好後呼叫（主執行緒）：記一筆 baseline 並註冊該視窗的觀察器；對同一視窗重裝才清舊狀態，不影響其他視窗
    static func install(on window: NSWindow) {
        pruneDeadStates()

        let key = ObjectIdentifier(window)
        let serial: Int
        if let existing = states[key] {
            let isSameWindow = (existing.window === window)
            existing.invalidate()
            states.removeValue(forKey: key)
            if isSameWindow {
                serial = existing.serial
            } else {
                serial = nextWindowSerial
                nextWindowSerial += 1
            }
        } else {
            serial = nextWindowSerial
            nextWindowSerial += 1
        }

        let state = WindowState(serial: serial, window: window)
        states[key] = state

        recordSnapshot(window: window, state: state, event: "安裝", allowAnomalyFollowUp: true)

        let nc = NotificationCenter.default
        state.tokens.append(nc.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak window, weak state] _ in
            MainActor.assumeIsolated {
                guard let state, states[key] === state else { return }
                guard let window else {
                    removeDeadState(key: key, state: state)
                    return
                }
                handleScreenOrBackingChange(window: window, state: state, event: "換螢幕")
            }
        })
        state.tokens.append(nc.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: window, queue: .main) { [weak window, weak state] _ in
            MainActor.assumeIsolated {
                guard let state, states[key] === state else { return }
                guard let window else {
                    removeDeadState(key: key, state: state)
                    return
                }
                handleScreenOrBackingChange(window: window, state: state, event: "換backing")
            }
        })
        state.tokens.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak window, weak state] _ in
            MainActor.assumeIsolated {
                guard let state, states[key] === state else { return }
                guard let window else {
                    removeDeadState(key: key, state: state)
                    return
                }
                recordSnapshot(window: window, state: state, event: "遮擋變化", allowAnomalyFollowUp: true)
            }
        })
        state.tokens.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak window, weak state] _ in
            MainActor.assumeIsolated {
                guard let state, states[key] === state else { return }
                guard let window else {
                    removeDeadState(key: key, state: state)
                    return
                }
                recordSnapshot(window: window, state: state, event: "取得焦點", allowAnomalyFollowUp: true)
            }
        })
        state.tokens.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak window, weak state] _ in
            MainActor.assumeIsolated {
                guard let state, states[key] === state else { return }
                guard let window else {
                    removeDeadState(key: key, state: state)
                    return
                }
                recordSnapshot(window: window, state: state, event: "失去焦點", allowAnomalyFollowUp: true)
            }
        })
        state.tokens.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak window, weak state] _ in
            MainActor.assumeIsolated {
                guard let state, states[key] === state else { return }
                guard let window else {
                    removeDeadState(key: key, state: state)
                    return
                }
                scheduleMoveCheck(window: window, state: state)
            }
        })

        if !screenParamsObserverRegistered {
            screenParamsObserverRegistered = true
            screenParamsObserverToken = nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    handleScreenParametersChanged()
                }
            }
        }
    }

    /// 純資料快照（主執行緒、不改視窗或 layer 任何狀態）
    static func snapshotLine(_ w: NSWindow, event: String) -> (line: String, anomalies: [String]) {
        let prevWN = states[ObjectIdentifier(w)].flatMap { $0.window === w ? $0.lastLoggedWindowNumber : nil }
        let built = buildSnapshotLine(w, event: event, previousWindowNumber: prevWN)
        return (line: built.line, anomalies: built.anomalies)
    }

    private static func buildSnapshotLine(
        _ w: NSWindow,
        event: String,
        previousWindowNumber: Int?
    ) -> (line: String, anomalies: [String], windowNumber: Int) {
        var anomalies: [String] = []

        // 螢幕
        let screenText = screenLabel(of: w)
        let scaleText = String(format: "%.1f", locale: posixLocale, Double(w.backingScaleFactor))
        let colorSpaceText = colorSpaceName(of: w)

        // 視窗
        let winAlpha = Double(w.alphaValue)
        let winAlphaText = fmt3(winAlpha)
        if winAlpha < 0.999 {
            anomalies.append("alpha-低")
        }
        if !w.isOpaque {
            anomalies.append("非不透明")
        }
        let bgText: String
        if let bg = srgbComponents(of: w.backgroundColor, appearance: w.effectiveAppearance) {
            bgText = String(format: "%.4f,%.4f,%.4f,%.4f", locale: posixLocale, Double(bg.r), Double(bg.g), Double(bg.b), Double(bg.a))
            if Double(bg.a) < 0.999 {
                anomalies.append("背景透明")
            }
        } else {
            bgText = "無"
        }
        let occText = w.occlusionState.contains(.visible) ? "visible" : "hidden"

        // 內容層（只讀，不觸發 wantsLayer）
        let layerOpacityText: String
        let layerOpaqueText: String
        let layerBgAlphaText: String
        if let layer = w.contentView?.layer {
            let opacity = Double(layer.opacity)
            layerOpacityText = fmt3(opacity)
            layerOpaqueText = "\(layer.isOpaque)"
            if let bgCG = layer.backgroundColor {
                layerBgAlphaText = fmt3(Double(bgCG.alpha))
            } else {
                layerBgAlphaText = "無"
            }
            if opacity < 0.999 {
                anomalies.append("內容層透明")
            }
        } else {
            layerOpacityText = "無"
            layerOpaqueText = "無"
            layerBgAlphaText = "無"
        }

        let viewAlphaText: String
        if let contentView = w.contentView {
            let viewAlpha = Double(contentView.alphaValue)
            viewAlphaText = fmt3(viewAlpha)
            if viewAlpha < 0.999 {
                anomalies.append("內容view-alpha-低")
            }
        } else {
            viewAlphaText = "無"
        }

        // 子層異常（子 view 遞迴最多深度 4、最多檢查 400 個 view、列前 8 個）
        let subviewItems = collectAnomalousSubviews(root: w.contentView)
        let subviewText = subviewItems.isEmpty ? "無" : subviewItems.joined(separator: ",")
        if !subviewItems.isEmpty {
            anomalies.append("子層透明")
        }

        // 每次診斷都重新讀 windowNumber，避免快取舊號造成量測假象
        let currentWN = w.windowNumber

        // WindowServer（既有欄位保留不動：以 .optionIncludingWindow 查本視窗）
        var wsAlphaText = "無"
        var wsOnscreenText = "無"
        var wsLayerText = "無"
        var wsInfo: [String: Any]?
        if currentWN > 0,
           let wid = CGWindowID(exactly: currentWN),
           let cfList = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid),
           let list = cfList as? [[String: Any]],
           let info = list.first {
            wsInfo = info
            if let alphaNum = info[kCGWindowAlpha as String] as? NSNumber {
                let a = alphaNum.doubleValue
                wsAlphaText = fmt3(a)
                if a < 0.999 {
                    anomalies.append("WS-alpha-低")
                }
            }
            if let on = info[kCGWindowIsOnscreen as String] as? Bool {
                wsOnscreenText = "\(on)"
            } else if let onNum = info[kCGWindowIsOnscreen as String] as? NSNumber {
                wsOnscreenText = "\(onNum.boolValue)"
            }
            if let layerNum = info[kCGWindowLayer as String] as? NSNumber {
                wsLayerText = "\(layerNum.intValue)"
            }
        }

        let onActiveSpace = w.isOnActiveSpace
        let spaceText = WindowSnapshotFormatter.extractWorkspaceID(from: wsInfo)

        // 第 2 輪 A.1 追加欄位（座標、螢幕清單、activeDisplays、frameInUnion、可見/隱藏/行為/層級/父子、wn/wnChanged、.optionAll cgAll）
        let winFrame = WindowSnapshotRect(w.frame)
        let screenID = w.screen.flatMap { displayID(of: $0) }
        let allScreens = collectDiagScreenInfos()
        let activeDisplays = queryActiveDisplayIDs()
        let liveFrameInUnion = WindowDiagFieldsFormatter.isFrameInUnion(
            frame: winFrame,
            screens: allScreens,
            activeDisplayIDs: activeDisplays
        )
        let frameInUnion: Bool
        if w === monitoredMainWindow, let forcedOut = injectedOverride?.frameOutOfBounds {
            frameInUnion = !forcedOut
        } else {
            frameInUnion = liveFrameInUnion
        }
        let cgAllDict = queryWindowServerInfoOptionAll(for: currentWN)
        let cgAllInfo = WindowDiagFieldsFormatter.parseCGAllInfo(from: cgAllDict)
        let extended = WindowDiagExtendedFields(
            frame: winFrame,
            screenID: screenID,
            screens: allScreens,
            activeDisplays: activeDisplays,
            frameInUnion: frameInUnion,
            isVisible: w.isVisible,
            isMiniaturized: w.isMiniaturized,
            appHidden: NSApp.isHidden,
            collectionBehaviorRaw: w.collectionBehavior.rawValue,
            level: w.level.rawValue,
            parentWindowNumber: w.parent?.windowNumber,
            childWindowNumbers: (w.childWindows ?? []).map(\.windowNumber),
            windowNumber: currentWN,
            previousWindowNumber: previousWindowNumber,
            cgAll: cgAllInfo
        )

        let eventHeader: String
        if let serial = windowSerial(for: w) {
            eventHeader = "事件=\(event) 視窗#\(serial)"
        } else {
            eventHeader = "事件=\(event)"
        }
        let anomalyText = anomalies.isEmpty ? "無" : anomalies.joined(separator: ",")
        let baseLine = "\(eventHeader) | 螢幕=\(screenText) scale=\(scaleText) 色域=\(colorSpaceText) | 視窗 alpha=\(winAlphaText) opaque=\(w.isOpaque) 背景=\(bgText) key=\(w.isKeyWindow) main=\(w.isMainWindow) occ=\(occText) | 內容層 opacity=\(layerOpacityText) opaque=\(layerOpaqueText) 背景alpha=\(layerBgAlphaText) view_alpha=\(viewAlphaText) | 子層異常=\(subviewText) | WindowServer alpha=\(wsAlphaText) onscreen=\(wsOnscreenText) layer=\(wsLayerText) | 異常=\(anomalyText)"
        let line = baseLine
            + WindowSnapshotFormatter.formatWindowDiagSpaceSuffix(onActiveSpace: onActiveSpace, space: spaceText)
            + WindowDiagFieldsFormatter.formatExtendedSuffix(extended)
        return (line: line, anomalies: anomalies, windowNumber: currentWN)
    }

    // MARK: 觀察排程與節流（主執行緒）

    private static func windowSerial(for window: NSWindow) -> Int? {
        let key = ObjectIdentifier(window)
        guard let state = states[key], state.window === window else { return nil }
        return state.serial
    }

    private static func pruneDeadStates() {
        let deadKeys = states.compactMap { (key, state) -> ObjectIdentifier? in
            state.window == nil ? key : nil
        }
        for key in deadKeys {
            states[key]?.invalidate()
            states.removeValue(forKey: key)
        }
    }

    private static func removeDeadState(key: ObjectIdentifier, state: WindowState) {
        if states[key] === state {
            state.invalidate()
            states.removeValue(forKey: key)
        }
        pruneDeadStates()
    }

    private static func handleScreenParametersChanged() {
        pruneDeadStates()
        let liveStates = states.values
            .filter { $0.window != nil }
            .sorted { $0.serial < $1.serial }
        for state in liveStates {
            guard let window = state.window else { continue }
            recordSnapshot(window: window, state: state, event: "螢幕參數變化", allowAnomalyFollowUp: true)
        }
    }

    private static func handleScreenOrBackingChange(window: NSWindow, state: WindowState, event: String) {
        recordSnapshot(window: window, state: state, event: event, allowAnomalyFollowUp: true)
        state.screenBackingFollowUpWork?.cancel()
        let key = ObjectIdentifier(window)
        let first = DispatchWorkItem { [weak window, weak state] in
            MainActor.assumeIsolated {
                guard let state, states[key] === state else { return }
                guard let window else {
                    removeDeadState(key: key, state: state)
                    return
                }
                recordSnapshot(window: window, state: state, event: "\(event)+0.3s", allowAnomalyFollowUp: true)
                let second = DispatchWorkItem { [weak window, weak state] in
                    MainActor.assumeIsolated {
                        guard let state, states[key] === state else { return }
                        state.screenBackingFollowUpWork = nil
                        guard let window else {
                            removeDeadState(key: key, state: state)
                            return
                        }
                        recordSnapshot(window: window, state: state, event: "\(event)+2s", allowAnomalyFollowUp: true)
                    }
                }
                state.screenBackingFollowUpWork = second
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: second)
            }
        }
        state.screenBackingFollowUpWork = first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: first)
    }

    private static func scheduleMoveCheck(window: NSWindow, state: WindowState) {
        state.moveDebounceWork?.cancel()
        let key = ObjectIdentifier(window)
        let work = DispatchWorkItem { [weak window, weak state] in
            MainActor.assumeIsolated {
                guard let state, states[key] === state else { return }
                state.moveDebounceWork = nil
                guard let window else {
                    removeDeadState(key: key, state: state)
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                guard canLog(state: state, event: "移動", now: now) else { return }
                let snap = buildSnapshotLine(window, event: "移動", previousWindowNumber: state.lastLoggedWindowNumber)
                let currentScreen = screenIdentity(of: window)
                let screenChanged = (currentScreen != state.lastLoggedScreen)
                if screenChanged || !snap.anomalies.isEmpty {
                    emit(snap: snap, window: window, state: state, event: "移動", now: now, allowAnomalyFollowUp: true)
                }
            }
        }
        state.moveDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private static func recordSnapshot(window: NSWindow, state: WindowState, event: String, allowAnomalyFollowUp: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard canLog(state: state, event: event, now: now) else { return }
        let snap = buildSnapshotLine(window, event: event, previousWindowNumber: state.lastLoggedWindowNumber)
        emit(snap: snap, window: window, state: state, event: event, now: now, allowAnomalyFollowUp: allowAnomalyFollowUp)
    }

    private static func canLog(state: WindowState, event: String, now: TimeInterval) -> Bool {
        if let prev = state.lastLoggedTimeByEvent[event], now - prev < eventDedupeInterval {
            return false
        }
        loggedTimestamps.removeAll { now - $0 >= rateLimitWindow }
        return loggedTimestamps.count < maxLinesPerMinute
    }

    private static func emit(
        snap: (line: String, anomalies: [String], windowNumber: Int),
        window: NSWindow,
        state: WindowState,
        event: String,
        now: TimeInterval,
        allowAnomalyFollowUp: Bool
    ) {
        state.lastLoggedTimeByEvent[event] = now
        loggedTimestamps.append(now)
        state.lastLoggedScreen = screenIdentity(of: window)
        state.lastLoggedWindowNumber = snap.windowNumber

        let hasAnomaly = !snap.anomalies.isEmpty
        EventLog.log(hasAnomaly ? "視窗診斷!" : "視窗診斷", snap.line)
        if hasAnomaly && allowAnomalyFollowUp {
            scheduleAnomalyFollowUp(window: window, state: state, baseEvent: event)
        }
        if snap.anomalies.contains(where: { recoverableAnomalies.contains($0) }) {
            WindowDiagRestore.scheduleCheck(window: window, trigger: event)
        }
    }

    private static func scheduleAnomalyFollowUp(window: NSWindow, state: WindowState, baseEvent: String) {
        guard !state.anomalyFollowUpActive else { return }
        state.anomalyFollowUpActive = true
        state.anomalyWork1s?.cancel()
        state.anomalyWork5s?.cancel()

        let key = ObjectIdentifier(window)
        let w1 = DispatchWorkItem { [weak window, weak state] in
            MainActor.assumeIsolated {
                guard let state, states[key] === state else { return }
                state.anomalyWork1s = nil
                guard let window else {
                    removeDeadState(key: key, state: state)
                    return
                }
                recordSnapshot(window: window, state: state, event: "\(baseEvent)+1s", allowAnomalyFollowUp: false)
            }
        }
        let w5 = DispatchWorkItem { [weak window, weak state] in
            MainActor.assumeIsolated {
                guard let state, states[key] === state else { return }
                state.anomalyWork5s = nil
                state.anomalyFollowUpActive = false
                guard let window else {
                    removeDeadState(key: key, state: state)
                    return
                }
                recordSnapshot(window: window, state: state, event: "\(baseEvent)+5s", allowAnomalyFollowUp: false)
            }
        }
        state.anomalyWork1s = w1
        state.anomalyWork5s = w5
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: w5)
    }

    // MARK: 資料收集輔助（純唯讀）

    private static func fmt3(_ value: Double) -> String {
        String(format: "%.3f", locale: posixLocale, value)
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func screenIdentity(of w: NSWindow) -> ScreenIdentity {
        guard let s = w.screen else { return .none }
        if let id = displayID(of: s) { return .display(id) }
        if let idx = NSScreen.screens.firstIndex(of: s) { return .index(idx) }
        return .none
    }

    private static func screenLabel(of w: NSWindow) -> String {
        guard let s = w.screen else { return "無" }
        let screens = NSScreen.screens
        let sid = displayID(of: s)
        let index = screens.firstIndex(of: s) ?? sid.flatMap { id in screens.firstIndex { displayID(of: $0) == id } }
        let kind: String
        if let sid {
            kind = CGDisplayIsBuiltin(sid) != 0 ? "內建" : "外接"
        } else {
            kind = "外接"
        }
        if let index {
            return "\(index + 1)（\(kind)）"
        }
        return "未知（\(kind)）"
    }

    private static func colorSpaceName(of w: NSWindow) -> String {
        guard let cs = w.colorSpace ?? w.screen?.colorSpace,
              let cfName = cs.cgColorSpace?.name else {
            return "無"
        }
        let raw = (cfName as String).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "無" }
        let prefix = "kCGColorSpace"
        let stripped = raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
        let normalized = stripped.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return "無" }
        return allowedColorSpaces[normalized] ?? "其他"
    }

    private static func srgbComponents(of color: NSColor?, appearance: NSAppearance) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
        guard let color else { return nil }
        var converted: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            converted = color.usingColorSpace(.sRGB)
        }
        guard let c = converted else { return nil }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    private static func collectAnomalousSubviews(root: NSView?) -> [String] {
        guard let root, !root.isHidden else { return [] }
        let maxDepth = 4
        let maxVisited = 400
        let maxReported = 8
        var queue: [(NSView, Int)] = root.subviews.map { ($0, 1) }
        var head = 0
        var visited = 0
        var results: [String] = []

        while head < queue.count && visited < maxVisited && results.count < maxReported {
            let (view, depth) = queue[head]
            head += 1
            guard !view.isHidden else { continue }
            visited += 1

            let vAlpha = Double(view.alphaValue)
            let lOpacity = view.layer.map { Double($0.opacity) }
            if vAlpha < 0.999 || (lOpacity.map { $0 < 0.999 } ?? false) {
                let rawName = String(describing: type(of: view))
                let className: String
                if let genericIdx = rawName.firstIndex(of: "<") {
                    className = String(rawName[..<genericIdx])
                } else {
                    className = rawName
                }
                let opacityStr = lOpacity.map { fmt3($0) } ?? "無"
                results.append("\(className)@\(depth):\(fmt3(vAlpha))/\(opacityStr)")
                if results.count >= maxReported {
                    break
                }
            }

            if depth < maxDepth {
                for sub in view.subviews {
                    queue.append((sub, depth + 1))
                }
            }
        }
        return results
    }

    // MARK: 視窗卡住（非作用中 Space／WS 非 onscreen）輕量偵測與現場快照（純唯讀、不修視窗）

    /// 在主視窗建立後啟動偵測器：只掛系統通知，僅在條件可能成立時排一個 1.5 秒單次計時器，不跑常駐輪詢
    static func startStuckMonitor(mainWindow: NSWindow) {
        stopStuckMonitor()
        monitoredMainWindow = mainWindow
        stuckDetector.reset()

        let nc = NotificationCenter.default
        let windowNotifs: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didResignMainNotification,
            NSWindow.didChangeScreenNotification,
        ]
        for name in windowNotifs {
            stuckObserverTokens.append(nc.addObserver(forName: name, object: mainWindow, queue: .main) { _ in
                MainActor.assumeIsolated {
                    evaluateStuckMonitorNow()
                }
            })
        }

        let appNotifs: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didChangeScreenParametersNotification,
        ]
        for name in appNotifs {
            stuckObserverTokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    evaluateStuckMonitorNow()
                }
            })
        }

        workspaceObserverToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                evaluateStuckMonitorNow()
            }
        }

        evaluateStuckMonitorNow()
        startFocusSourceObservers()
        startAlphaScanObservers(mainWindow: mainWindow)
        rescueCoordinator.cancelAndReset(resetHistory: true)
    }

    static func stopStuckMonitor() {
        let nc = NotificationCenter.default
        for token in stuckObserverTokens {
            nc.removeObserver(token)
        }
        stuckObserverTokens.removeAll()
        if let token = workspaceObserverToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            workspaceObserverToken = nil
        }
        cancelPendingStuckCheck()
        stopFocusSourceObservers()
        stopAlphaScanObservers()
        rescueCoordinator.cancelAndReset(resetHistory: false)
        monitoredMainWindow = nil
        injectedOverride = nil
    }

    /// 測試鉤子（只在 --state-dir 測試實例由 TestHarness 呼叫）：覆寫偵測器讀到的主視窗狀態並立即重新評估
    static func applyTestInjection(_ command: WindowDiagInjectCommand) {
        if command.clear {
            injectedOverride = nil
        } else {
            var current = injectedOverride ?? WindowDiagOverride()
            current.merge(command.patch)
            injectedOverride = current.hasAnyOverride ? current : nil
        }
        evaluateStuckMonitorNow()
        if !command.clear, let nodes = command.patch.alphaNodes, !nodes.isEmpty {
            runAlphaScanNow(window: monitoredMainWindow, trigger: "inject", source: "inject")
        }
    }

    /// 立即對主視窗取樣一次並推進偵測狀態機（純唯讀，不改任何視窗屬性）
    static func evaluateStuckMonitorNow() {
        guard let mainWindow = monitoredMainWindow else {
            cancelPendingStuckCheck()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let liveSample = sampleMainWindow(mainWindow)
        let effectiveSample = injectedOverride?.applying(to: liveSample) ?? liveSample
        let decision = stuckDetector.evaluate(effectiveSample, at: now)

        switch decision {
        case .idle, .suppressedSameIncident, .suppressedSessionLimit:
            cancelPendingStuckCheck()
        case .pending(let remaining):
            scheduleStuckCheck(after: max(0.01, remaining), now: now)
        case .suppressedCooldown(let remaining):
            scheduleStuckCheck(after: max(0.01, remaining), now: now)
        case .emit(let trigger, let sequence):
            cancelPendingStuckCheck()
            let snapshot = collectSnapshotData(
                mainWindow: mainWindow,
                sample: effectiveSample,
                trigger: trigger,
                sequence: sequence
            )
            WindowSnapshotFormatter.emitSnapshot(snapshot)
        }
    }

    /// `applicationShouldHandleReopen`（點 Dock）被呼叫時寫一筆「視窗診斷」（純唯讀，不改變 App 行為）
    static func recordDockReopen(
        window: NSWindow?,
        isAppActive: Bool,
        hasVisibleWindows: Bool,
        sink: ((String, String) -> Void)? = nil
    ) {
        let state: DockReopenSnapshot
        if let window {
            state = DockReopenSnapshot(
                hasWindow: true,
                isOnActiveSpace: window.isOnActiveSpace,
                occVisible: window.occlusionState.contains(.visible),
                isVisible: window.isVisible,
                isKeyWindow: window.isKeyWindow,
                isMiniaturized: window.isMiniaturized,
                isAppActive: isAppActive,
                hasVisibleWindows: hasVisibleWindows
            )
        } else {
            state = DockReopenSnapshot(
                hasWindow: false,
                isOnActiveSpace: nil,
                occVisible: nil,
                isVisible: nil,
                isKeyWindow: nil,
                isMiniaturized: nil,
                isAppActive: isAppActive,
                hasVisibleWindows: hasVisibleWindows
            )
        }
        let line = WindowSnapshotFormatter.formatDockReopenLine(state)
        if let sink {
            sink(WindowSnapshotFormatter.diagnosticCategory, line)
        } else {
            EventLog.log(WindowSnapshotFormatter.diagnosticCategory, line)
            evaluateStuckMonitorNow()
        }
    }

    private static func cancelPendingStuckCheck() {
        stuckCheckWork?.cancel()
        stuckCheckWork = nil
        stuckCheckDeadline = nil
    }

    private static func scheduleStuckCheck(after delay: TimeInterval, now: TimeInterval) {
        let targetDeadline = now + delay
        if stuckCheckWork != nil, let existing = stuckCheckDeadline, existing <= targetDeadline + 0.05 {
            return
        }
        cancelPendingStuckCheck()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                stuckCheckWork = nil
                stuckCheckDeadline = nil
                evaluateStuckMonitorNow()
            }
        }
        stuckCheckWork = work
        stuckCheckDeadline = targetDeadline
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func sampleMainWindow(_ window: NSWindow) -> WindowStuckSample {
        let isActive = NSApp.isActive
        let isKey = window.isKeyWindow
        let isMain = window.isMainWindow
        let occVisible = window.occlusionState.contains(.visible)

        // 若測試已覆寫 wsOnscreen 或 key/main 皆為 false（條件 B 不可能成立），避免不必要的 WindowServer IPC
        let effectiveKey = injectedOverride?.isKey ?? isKey
        let effectiveMain = injectedOverride?.isMain ?? isMain
        let wsOnscreen: Bool?
        if injectedOverride?.wsOnscreen != nil {
            wsOnscreen = true
        } else if effectiveKey || effectiveMain {
            wsOnscreen = queryWindowServerOnscreen(from: queryWindowServerInfo(for: window))
        } else {
            wsOnscreen = true
        }

        return WindowStuckSample(
            isActive: isActive,
            isKey: isKey,
            isMain: isMain,
            occVisible: occVisible,
            wsOnscreen: wsOnscreen
        )
    }

    private static func queryWindowServerInfo(for window: NSWindow) -> [String: Any]? {
        guard window.windowNumber > 0,
              let wid = CGWindowID(exactly: window.windowNumber),
              let cfList = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid),
              let list = cfList as? [[String: Any]] else {
            return nil
        }
        return list.first
    }

    private static func queryWindowServerOnscreen(from info: [String: Any]?) -> Bool? {
        guard let info else { return nil }
        if let on = info[kCGWindowIsOnscreen as String] as? Bool {
            return on
        }
        if let onNum = info[kCGWindowIsOnscreen as String] as? NSNumber {
            return onNum.boolValue
        }
        return nil
    }

    private static func collectSnapshotData(
        mainWindow: NSWindow,
        sample: WindowStuckSample,
        trigger: WindowStuckTrigger,
        sequence: Int
    ) -> WindowSnapshotData {
        let screens = collectScreens()
        let primaryHeight = primaryScreenHeight(from: NSScreen.screens)
        let ownWindows = collectOwnWindows(mainWindow: mainWindow, effectiveSample: sample)
        let environment = collectEnvironment()
        let onscreenExternal = collectOnscreenExternalWindows(primaryScreenHeight: primaryHeight)

        let myPID = ProcessInfo.processInfo.processIdentifier
        let ourWID = mainWindow.windowNumber > 0 ? CGWindowID(exactly: mainWindow.windowNumber) : nil
        let ourFrame = WindowSnapshotRect(mainWindow.frame)
        let ourScreenFrame = mainWindow.screen.map { WindowSnapshotRect($0.frame) }

        let fullscreenMatches = WindowSnapshotFormatter.detectFullscreenLayer0Windows(
            onscreenWindows: onscreenExternal,
            screens: screens,
            ourPID: myPID
        )
        let aboveWindows = WindowSnapshotFormatter.filterAboveWindows(
            allOnscreenFrontToBack: onscreenExternal,
            ourWindowNumber: ourWID,
            ourPID: myPID,
            ourFrame: ourFrame,
            ourScreenFrame: ourScreenFrame
        )
        let mainOnActiveSpace = injectedOverride?.isOnActiveSpace ?? mainWindow.isOnActiveSpace
        let source = (injectedOverride?.hasAnyOverride == true) ? "inject" : "live"

        return WindowSnapshotData(
            sequence: sequence,
            trigger: trigger,
            source: source,
            sample: sample,
            mainOnActiveSpace: mainOnActiveSpace,
            screens: screens,
            ownWindows: ownWindows,
            environment: environment,
            fullscreenLayer0Matches: fullscreenMatches,
            aboveWindows: aboveWindows
        )
    }

    private static func primaryScreenHeight(from screens: [NSScreen]) -> CGFloat {
        if let primary = screens.first(where: { abs($0.frame.origin.x) < 0.5 && abs($0.frame.origin.y) < 0.5 }) {
            return primary.frame.height
        }
        if let first = screens.first {
            return first.frame.height
        }
        return CGDisplayBounds(CGMainDisplayID()).height
    }

    private static func collectScreens() -> [WindowSnapshotScreen] {
        let list = NSScreen.screens
        let mainScreen = NSScreen.main
        return list.enumerated().map { idx, screen in
            let sid = displayID(of: screen)
            let kind = sid.map { CGDisplayIsBuiltin($0) != 0 ? "內建" : "外接" } ?? "外接"
            let f = screen.frame
            let vf = screen.visibleFrame
            let scale = Double(screen.backingScaleFactor)
            let pxW = Int((f.width * screen.backingScaleFactor).rounded())
            let pxH = Int((f.height * screen.backingScaleFactor).rounded())
            let isPrimary = (idx == 0) || (abs(f.origin.x) < 0.5 && abs(f.origin.y) < 0.5)
            return WindowSnapshotScreen(
                index: idx + 1,
                kind: kind,
                isPrimary: isPrimary,
                isMain: screen == mainScreen,
                pixelWidth: pxW,
                pixelHeight: pxH,
                scale: scale,
                frame: WindowSnapshotRect(f),
                visibleFrame: WindowSnapshotRect(vf)
            )
        }
    }

    private static func collectOwnWindows(
        mainWindow: NSWindow,
        effectiveSample: WindowStuckSample
    ) -> [WindowSnapshotOwnWindow] {
        // 第 2 輪 A.2：列出 NSApp.windows 全部（含 NSPanel、通知小視窗、輪盤，含目前不可見者），最多 40 筆，以 .optionAll 查 onscreen，不記標題
        var ordered: [NSWindow] = [mainWindow]
        let others = NSApp.windows.filter { $0 !== mainWindow }
        let remainingCap = max(0, WindowSnapshotFormatter.maxOwnWindows - 1)
        ordered.append(contentsOf: others.prefix(remainingCap))

        let allCGMap = queryAllWindowsOptionAllMap()

        return ordered.enumerated().map { idx, w in
            let isPrimaryMain = (w === mainWindow)
            let wn = w.windowNumber
            let wsInfo = wn > 0 ? allCGMap[wn] : nil
            let liveWsOnscreen = queryWindowServerOnscreen(from: wsInfo)
            let space = WindowSnapshotFormatter.extractWorkspaceID(from: wsInfo)
            let onActiveSpace = isPrimaryMain ? (injectedOverride?.isOnActiveSpace ?? w.isOnActiveSpace) : w.isOnActiveSpace
            let occVisible = isPrimaryMain ? effectiveSample.occVisible : w.occlusionState.contains(.visible)
            let isKey = isPrimaryMain ? effectiveSample.isKey : w.isKeyWindow
            let isMain = isPrimaryMain ? effectiveSample.isMain : w.isMainWindow
            let wsOnscreen = isPrimaryMain ? effectiveSample.wsOnscreen : liveWsOnscreen
            let clsName = WindowDiagFieldsFormatter.sanitizedClassName(String(describing: type(of: w)))

            return WindowSnapshotOwnWindow(
                index: idx + 1,
                isPrimaryMainWindow: isPrimaryMain,
                frame: WindowSnapshotRect(w.frame),
                isOnActiveSpace: onActiveSpace,
                isVisible: w.isVisible,
                occVisible: occVisible,
                isKey: isKey,
                isMain: isMain,
                isMiniaturized: w.isMiniaturized,
                screenLabel: screenLabel(of: w),
                level: w.level.rawValue,
                wsOnscreen: wsOnscreen,
                space: space,
                collectionBehaviorRaw: w.collectionBehavior.rawValue,
                alpha: Double(w.alphaValue),
                windowNumber: wn,
                windowClass: clsName
            )
        }
    }

    private static func collectEnvironment() -> WindowSnapshotEnvironment {
        let front = NSWorkspace.shared.frontmostApplication
        let myPID = ProcessInfo.processInfo.processIdentifier
        return WindowSnapshotEnvironment(
            screensHaveSeparateSpaces: NSScreen.screensHaveSeparateSpaces,
            presentationOptionsRaw: NSApplication.shared.presentationOptions.rawValue,
            menuBarVisible: NSMenu.menuBarVisible(),
            frontmostAppName: front?.localizedName ?? front?.bundleIdentifier,
            frontmostActivationPolicy: WindowSnapshotFormatter.formatActivationPolicy(front?.activationPolicy),
            frontmostIsSelf: front.map { $0.processIdentifier == myPID }
        )
    }

    private static func collectOnscreenExternalWindows(primaryScreenHeight: CGFloat) -> [WindowSnapshotExternalWindow] {
        guard let cfList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID),
              let list = cfList as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let num = info[kCGWindowNumber as String] as? NSNumber,
                  let pidNum = info[kCGWindowOwnerPID as String] as? NSNumber else {
                return nil
            }
            var cgRect = CGRect.zero
            if let dict = info[kCGWindowBounds as String] as? NSDictionary {
                CGRectMakeWithDictionaryRepresentation(dict, &cgRect)
            }
            let appKitRect = WindowSnapshotFormatter.convertCGToAppKitRect(cgRect, primaryScreenHeight: primaryScreenHeight)
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? "未知"
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            let isOnscreen: Bool?
            if let b = info[kCGWindowIsOnscreen as String] as? Bool {
                isOnscreen = b
            } else if let n = info[kCGWindowIsOnscreen as String] as? NSNumber {
                isOnscreen = n.boolValue
            } else {
                isOnscreen = nil
            }
            // 絕不讀也不存 kCGWindowName，避免洩漏其他程式的視窗標題
            return WindowSnapshotExternalWindow(
                windowNumber: num.uint32Value,
                ownerPID: pidNum.int32Value,
                ownerName: owner,
                layer: layer,
                bounds: WindowSnapshotRect(appKitRect),
                alpha: alpha,
                isOnscreen: isOnscreen
            )
        }
    }

    // MARK: - 第 2 輪 A.1／A.2 查詢輔助（CGGetActiveDisplayList、.optionAll）

    private static func collectDiagScreenInfos() -> [WindowDiagScreenInfo] {
        NSScreen.screens.map { s in
            WindowDiagScreenInfo(displayID: displayID(of: s), frame: WindowSnapshotRect(s.frame))
        }
    }

    private static func queryActiveDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var list = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &list, &count) == .success else { return [] }
        return Array(list.prefix(Int(count)))
    }

    private static func queryAllWindowsOptionAllMap() -> [Int: [String: Any]] {
        guard let cfList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID),
              let list = cfList as? [[String: Any]] else {
            return [:]
        }
        var map: [Int: [String: Any]] = [:]
        map.reserveCapacity(list.count)
        for info in list {
            if let num = info[kCGWindowNumber as String] as? NSNumber {
                map[num.intValue] = info
            }
        }
        return map
    }

    private static func queryWindowServerInfoOptionAll(for windowNumber: Int) -> [String: Any]? {
        guard windowNumber > 0 else { return nil }
        guard let cfList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID),
              let list = cfList as? [[String: Any]] else {
            return nil
        }
        return list.first { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == windowNumber }
    }

    private static func primaryScreenVisibleFrame() -> WindowSnapshotRect? {
        let screens = NSScreen.screens
        if let primary = screens.first(where: { abs($0.frame.origin.x) < 0.5 && abs($0.frame.origin.y) < 0.5 }) {
            return WindowSnapshotRect(primary.visibleFrame)
        }
        if let first = screens.first {
            return WindowSnapshotRect(first.visibleFrame)
        }
        if let main = NSScreen.main {
            return WindowSnapshotRect(main.visibleFrame)
        }
        return nil
    }

    // MARK: - 第 2 輪 A.3：焦點／前景化呼叫來源（純通知退路版，絕不 swizzle）

    private static func startFocusSourceObservers() {
        stopFocusSourceObservers()
        focusSourceRateLimiter.reset()

        let nc = NotificationCenter.default
        focusSourceObserverTokens.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                recordFocusSourceEvent(kind: .appBecomeActive, window: nil)
            }
        })
        focusSourceObserverTokens.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                recordFocusSourceEvent(kind: .appResignActive, window: nil)
            }
        })
        focusSourceObserverTokens.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let win = note.object as? NSWindow
            MainActor.assumeIsolated {
                recordFocusSourceEvent(kind: .winBecomeKey, window: win)
            }
        })
        focusSourceObserverTokens.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
            let win = note.object as? NSWindow
            MainActor.assumeIsolated {
                recordFocusSourceEvent(kind: .winResignKey, window: win)
            }
        })
    }

    private static func stopFocusSourceObservers() {
        let nc = NotificationCenter.default
        for token in focusSourceObserverTokens {
            nc.removeObserver(token)
        }
        focusSourceObserverTokens.removeAll()
    }

    private static func recordFocusSourceEvent(kind: WindowDiagFocusEventKind, window: NSWindow?) {
        let now = ProcessInfo.processInfo.systemUptime
        guard focusSourceRateLimiter.allow(key: kind.rawValue, at: now) else { return }

        let symbols = WindowDiagCallStackFormatter.extractSymbolNames(
            from: Thread.callStackSymbols,
            maxFrames: WindowDiagCallStackFormatter.defaultMaxFrames,
            skipSubstrings: ["recordFocusSourceEvent", "startFocusSourceObservers"]
        )
        let front = NSWorkspace.shared.frontmostApplication
        let winClass = window.map { String(describing: type(of: $0)) }
        let wn = window?.windowNumber
        let line = WindowDiagCallStackFormatter.formatFocusSourceLine(
            kind: kind,
            frontAppName: front?.localizedName,
            frontBundleID: front?.bundleIdentifier,
            windowClass: winClass,
            windowNumber: wn,
            symbols: symbols
        )
        EventLog.log(WindowSnapshotFormatter.diagnosticCategory, line)
    }

    // MARK: - 第 2 輪 B：主視窗半透明掃描（純唯讀，只在失去焦點／換螢幕／拖曳結束觸發）

    private static func startAlphaScanObservers(mainWindow: NSWindow) {
        stopAlphaScanObservers()

        let nc = NotificationCenter.default
        alphaScanObserverTokens.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: mainWindow, queue: .main) { [weak mainWindow] _ in
            MainActor.assumeIsolated {
                scheduleAlphaScan(window: mainWindow, trigger: "失去焦點", debounce: 0.25)
            }
        })
        alphaScanObserverTokens.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak mainWindow] _ in
            MainActor.assumeIsolated {
                scheduleAlphaScan(window: mainWindow, trigger: "失去焦點", debounce: 0.25)
            }
        })
        alphaScanObserverTokens.append(nc.addObserver(forName: NSWindow.didChangeScreenNotification, object: mainWindow, queue: .main) { [weak mainWindow] _ in
            MainActor.assumeIsolated {
                scheduleAlphaScan(window: mainWindow, trigger: "換螢幕", debounce: 0.25)
            }
        })
        alphaScanObserverTokens.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: mainWindow, queue: .main) { [weak mainWindow] _ in
            MainActor.assumeIsolated {
                scheduleAlphaScan(window: mainWindow, trigger: "拖曳結束", debounce: 0.4)
            }
        })
        alphaScanObserverTokens.append(nc.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: mainWindow, queue: .main) { [weak mainWindow] _ in
            MainActor.assumeIsolated {
                scheduleAlphaScan(window: mainWindow, trigger: "拖曳結束", debounce: 0.25)
            }
        })

        alphaScanMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak mainWindow] event in
            MainActor.assumeIsolated {
                guard let mainWindow, event.window === mainWindow else { return }
                if event.type == .leftMouseDragged {
                    alphaScanSawMouseDrag = true
                } else if event.type == .leftMouseUp, alphaScanSawMouseDrag {
                    alphaScanSawMouseDrag = false
                    scheduleAlphaScan(window: mainWindow, trigger: "拖曳結束", debounce: 0.25)
                }
            }
            return event
        }
    }

    private static func stopAlphaScanObservers() {
        let nc = NotificationCenter.default
        for token in alphaScanObserverTokens {
            nc.removeObserver(token)
        }
        alphaScanObserverTokens.removeAll()
        if let monitor = alphaScanMouseMonitor {
            NSEvent.removeMonitor(monitor)
            alphaScanMouseMonitor = nil
        }
        alphaScanSawMouseDrag = false
        for work in alphaScanDebounceByTrigger.values {
            work.cancel()
        }
        alphaScanDebounceByTrigger.removeAll()
    }

    /// 供外部拖曳結束點選用通知（不修改 view/layer，走與其他事件相同的 debounce）
    static func notifyDragEnded(window: NSWindow?) {
        guard let target = window ?? monitoredMainWindow, target === monitoredMainWindow else { return }
        scheduleAlphaScan(window: target, trigger: "拖曳結束", debounce: 0.25)
    }

    private static func scheduleAlphaScan(window: NSWindow?, trigger: String, debounce: TimeInterval) {
        guard let window, window === monitoredMainWindow else { return }
        alphaScanDebounceByTrigger[trigger]?.cancel()
        let work = DispatchWorkItem { [weak window] in
            MainActor.assumeIsolated {
                alphaScanDebounceByTrigger.removeValue(forKey: trigger)
                guard let window, window === monitoredMainWindow else { return }
                let hasInjected = !(injectedOverride?.alphaNodes?.isEmpty ?? true)
                runAlphaScanNow(window: window, trigger: trigger, source: hasInjected ? "inject" : "live")
            }
        }
        alphaScanDebounceByTrigger[trigger] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private static func runAlphaScanNow(window: NSWindow?, trigger: String, source: String) {
        var result = scanLiveViewTree(root: window?.contentView)
        if let injectedNodes = injectedOverride?.alphaNodes, !injectedNodes.isEmpty {
            for node in injectedNodes {
                if result.findings.count < AlphaScanner.defaultMaxFindings {
                    if let finding = AlphaScanner.evaluateNode(
                        path: node.path,
                        viewAlpha: nil,
                        layerOpacity: node.opacity,
                        presentationOpacity: nil,
                        animationKeys: []
                    ) {
                        result.findings.append(finding)
                    }
                } else {
                    result.truncatedByFindingLimit = true
                    break
                }
            }
        }
        guard !result.findings.isEmpty else { return }
        alphaScanSequence += 1
        AlphaScanFormatter.emit(sequence: alphaScanSequence, trigger: trigger, source: source, result: result)
    }

    /// 純唯讀遞迴掃描主視窗 contentView 底下的 view 與 layer（絕不設 wantsLayer、不修改任何狀態）
    static func scanLiveViewTree(
        root: NSView?,
        threshold: Double = AlphaScanner.defaultThreshold,
        maxFindings: Int = AlphaScanner.defaultMaxFindings,
        maxVisitedNodes: Int = AlphaScanner.defaultMaxVisitedNodes
    ) -> AlphaScanResult {
        guard let root else {
            return AlphaScanResult(findings: [], visitedNodes: 0, truncatedByNodeLimit: false, truncatedByFindingLimit: false)
        }

        var findings: [AlphaScanFinding] = []
        var visited = 0
        var truncatedByNodes = false
        var truncatedByFindings = false
        var visitedLayers: Set<ObjectIdentifier> = []

        func visitStandaloneLayer(_ layer: CALayer, path: String) {
            if visited >= maxVisitedNodes {
                truncatedByNodes = true
                return
            }
            guard !layer.isHidden else { return }
            guard visitedLayers.insert(ObjectIdentifier(layer)).inserted else { return }
            visited += 1

            let layerOpacity = Double(layer.opacity)
            let presOpacity = layer.presentation().map { Double($0.opacity) }
            let animKeys = layer.animationKeys() ?? []
            if let finding = AlphaScanner.evaluateNode(
                path: path,
                viewAlpha: nil,
                layerOpacity: layerOpacity,
                presentationOpacity: presOpacity,
                animationKeys: animKeys,
                threshold: threshold
            ) {
                if findings.count < maxFindings {
                    findings.append(finding)
                } else {
                    truncatedByFindings = true
                    return
                }
            }

            if let sublayers = layer.sublayers {
                for (idx, sub) in sublayers.enumerated() {
                    if visited >= maxVisitedNodes {
                        truncatedByNodes = true
                        return
                    }
                    if truncatedByFindings { return }
                    let cls = WindowDiagFieldsFormatter.sanitizedClassName(String(describing: type(of: sub)))
                    visitStandaloneLayer(sub, path: "\(path)/L:\(cls)[\(idx)]")
                }
            }
        }

        func visitView(_ view: NSView, path: String) {
            if visited >= maxVisitedNodes {
                truncatedByNodes = true
                return
            }
            guard !view.isHidden else { return }
            visited += 1

            // 只讀既有 layer，絕不觸發 wantsLayer
            let layer = view.layer
            var layerOpacity: Double?
            var presOpacity: Double?
            var animKeys: [String] = []
            if let layer {
                visitedLayers.insert(ObjectIdentifier(layer))
                if !layer.isHidden {
                    layerOpacity = Double(layer.opacity)
                    presOpacity = layer.presentation().map { Double($0.opacity) }
                    animKeys = layer.animationKeys() ?? []
                }
            }

            if let finding = AlphaScanner.evaluateNode(
                path: path,
                viewAlpha: Double(view.alphaValue),
                layerOpacity: layerOpacity,
                presentationOpacity: presOpacity,
                animationKeys: animKeys,
                threshold: threshold
            ) {
                if findings.count < maxFindings {
                    findings.append(finding)
                } else {
                    truncatedByFindings = true
                    return
                }
            }

            // 先走訪子 view（會把子 view 的 backing layer 標記進 visitedLayers）
            for (idx, sub) in view.subviews.enumerated() {
                if visited >= maxVisitedNodes {
                    truncatedByNodes = true
                    return
                }
                if truncatedByFindings { return }
                let cls = WindowDiagFieldsFormatter.sanitizedClassName(String(describing: type(of: sub)))
                visitView(sub, path: "\(path)/\(cls)[\(idx)]")
            }

            // 再走訪非 view backing 的獨立子 layer（例如殘留拖曳 snapshot layer）
            if let layer, !layer.isHidden, let sublayers = layer.sublayers {
                for (idx, subLayer) in sublayers.enumerated() {
                    if visited >= maxVisitedNodes {
                        truncatedByNodes = true
                        return
                    }
                    if truncatedByFindings { return }
                    if visitedLayers.contains(ObjectIdentifier(subLayer)) { continue }
                    let cls = WindowDiagFieldsFormatter.sanitizedClassName(String(describing: type(of: subLayer)))
                    visitStandaloneLayer(subLayer, path: "\(path)/L:\(cls)[\(idx)]")
                }
            }
        }

        let rootCls = WindowDiagFieldsFormatter.sanitizedClassName(String(describing: type(of: root)))
        visitView(root, path: "\(rootCls)[0]")

        return AlphaScanResult(
            findings: findings,
            visitedNodes: visited,
            truncatedByNodeLimit: truncatedByNodes,
            truncatedByFindingLimit: truncatedByFindings
        )
    }

    // MARK: - 第 2 輪 C：點 Dock 救援第一階段

    /// 由 AppDelegate.applicationShouldHandleReopen 呼叫：正常狀態完全不動視窗、不記「視窗救援」；
    /// 僅在異常時依序執行 3 步救援（① Space → ② 座標 → ③ orderOut+orderFront）。
    static func handleDockReopenRescue(window: NSWindow?) {
        guard let window else { return }
        let isMonitored = (window === monitoredMainWindow)
        if isMonitored, let rescueOutcome = injectedOverride?.rescueOutcome {
            let initialState = measureRescueState(for: window, applyOverride: true)
            let simTarget = SimulatedWindowRescueTarget(
                initialState: initialState,
                initialBehaviorRaw: window.collectionBehavior.rawValue,
                successOutcome: rescueOutcome
            )
            rescueCoordinator.trigger(target: simTarget)
            return
        }
        let liveTarget = LiveWindowRescueTarget(window: window, applyOverride: isMonitored)
        rescueCoordinator.trigger(target: liveTarget)
    }

    fileprivate static func measureRescueState(for window: NSWindow, applyOverride: Bool) -> WindowRescueState {
        let winFrame = WindowSnapshotRect(window.frame)
        let screens = collectDiagScreenInfos()
        let activeDisplays = queryActiveDisplayIDs()
        let liveFrameInUnion = WindowDiagFieldsFormatter.isFrameInUnion(
            frame: winFrame,
            screens: screens,
            activeDisplayIDs: activeDisplays
        )
        let liveWsOnscreen = queryWindowServerOnscreen(from: queryWindowServerInfoOptionAll(for: window.windowNumber))

        var state = WindowRescueState(
            isKey: window.isKeyWindow,
            isMain: window.isMainWindow,
            occVisible: window.occlusionState.contains(.visible),
            wsOnscreen: liveWsOnscreen,
            isOnActiveSpace: window.isOnActiveSpace,
            frame: winFrame,
            frameInUnion: liveFrameInUnion,
            primaryVisibleFrame: primaryScreenVisibleFrame()
        )
        if applyOverride, let override = injectedOverride {
            if let v = override.isKey { state.isKey = v }
            if let v = override.isMain { state.isMain = v }
            if let v = override.occVisible { state.occVisible = v }
            if let v = override.wsOnscreen { state.wsOnscreen = v }
            if let v = override.isOnActiveSpace { state.isOnActiveSpace = v }
            if let out = override.frameOutOfBounds { state.frameInUnion = !out }
        }
        return state
    }

    @MainActor
    private final class LiveWindowRescueTarget: WindowRescueTarget {
        private weak var window: NSWindow?
        private let applyOverride: Bool

        init(window: NSWindow, applyOverride: Bool) {
            self.window = window
            self.applyOverride = applyOverride
        }

        var collectionBehaviorRaw: UInt {
            get { window?.collectionBehavior.rawValue ?? 0 }
            set { window?.collectionBehavior = NSWindow.CollectionBehavior(rawValue: newValue) }
        }

        var frame: WindowSnapshotRect {
            window.map { WindowSnapshotRect($0.frame) } ?? WindowSnapshotRect(x: 0, y: 0, width: 0, height: 0)
        }

        func makeKeyAndOrderFront() {
            window?.makeKeyAndOrderFront(nil)
        }

        func setFrame(_ rect: WindowSnapshotRect) {
            window?.setFrame(rect.cgRect, display: true)
        }

        func orderOut() {
            window?.orderOut(nil)
        }

        func orderFront() {
            window?.orderFront(nil)
        }

        func observeWillClose(_ handler: @escaping @MainActor () -> Void) -> () -> Void {
            guard let window else { return {} }
            let token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    handler()
                }
            }
            return {
                NotificationCenter.default.removeObserver(token)
            }
        }

        func measureState() -> WindowRescueState {
            guard let window else {
                return WindowRescueState(
                    isKey: false,
                    isMain: false,
                    occVisible: false,
                    wsOnscreen: nil,
                    isOnActiveSpace: false,
                    frame: WindowSnapshotRect(x: 0, y: 0, width: 0, height: 0),
                    frameInUnion: false,
                    primaryVisibleFrame: nil
                )
            }
            return WindowDiag.measureRescueState(for: window, applyOverride: applyOverride)
        }
    }
}
