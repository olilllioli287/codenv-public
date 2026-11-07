import AppKit
import SwiftUI

/// 「工作中」綠點的柔和呼吸閃爍：一個全域時鐘給所有點共用（不是每個點一個 Timer）；
/// 沒有任何工作中的點、codenv 在背景、或開了「減少動態效果」時時鐘不跑，點維持實心
final class PulseClock: ObservableObject {
    static let shared = PulseClock()
    @Published private(set) var alpha: Double = 1
    private(set) var users = 0
    private var timer: Timer?
    private var active = NSApp?.isActive ?? true
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false
    static let period = 1.4

    private init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.active = true; self?.update() })
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.active = false; self?.update() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.update() })
    }

    func retain() { users += 1; update() }
    func release() { users = max(0, users - 1); update() }

    private func update() {
        let go = users > 0 && active && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if go, timer == nil {
            let t = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                let phase = ProcessInfo.processInfo.systemUptime.truncatingRemainder(dividingBy: Self.period) / Self.period
                self?.alpha = 0.675 + 0.325 * cos(phase * 2 * .pi)      // 1 → 0.35 → 1
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !go, let t = timer {
            t.invalidate(); timer = nil
            alpha = 1
        }
        isRunning = timer != nil
    }
}

/// 工作中才用這個（其他狀態用一般實心圓點）：出現時登記、消失時放掉
struct PulseDot: View {
    let color: Color
    let size: CGFloat
    @ObservedObject private var clock = PulseClock.shared
    var body: some View {
        Circle().fill(color).frame(width: size, height: size).opacity(clock.alpha)
            .onAppear { clock.retain() }
            .onDisappear { clock.release() }
    }
}
