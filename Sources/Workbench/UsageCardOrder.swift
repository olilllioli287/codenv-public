import Combine
import CoreGraphics
import Foundation

/// F12 額度面板卡片順序的純函式：讀寫解析、保留隱藏卡位置與拖曳插入。
enum UsageCardOrder {
    static let defaultsKey = "usageCardOrder"

    enum DropTarget: Equatable {
        case before(String)
        case after(String)
        case end
    }

    static func poolKey(_ pool: UsagePool) -> String {
        "pool:\(pool.rawValue)"
    }

    static func extraKey(_ pool: ExtraKeyPool) -> String {
        "extra:\(pool.name)"
    }

    /// 驗證儲存值必須是純字串陣列；損壞或非字串陣列一律視同沒存（回空陣列）。
    static func decodeSavedOrder(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for element in array {
            guard let key = element as? String else { return [] }
            if !key.isEmpty, seen.insert(key).inserted {
                out.append(key)
            }
        }
        return out
    }

    static func loadSavedOrder(from defaults: UserDefaults = appDefaults) -> [String] {
        decodeSavedOrder(defaults.object(forKey: defaultsKey))
    }

    static func saveOrder(_ order: [String], to defaults: UserDefaults = appDefaults) {
        defaults.set(order, forKey: defaultsKey)
    }

    /// 讀：已存且目前存在的 key 照存的順序；目前存在但沒存過的排最後、維持預設順序；存了但目前不存在的忽略。
    static func orderedKeys(currentKeys: [String], savedOrder: [String]) -> [String] {
        var uniqueCurrent: [String] = []
        var currentSet = Set<String>()
        for key in currentKeys where !key.isEmpty {
            if currentSet.insert(key).inserted {
                uniqueCurrent.append(key)
            }
        }

        var emitted = Set<String>()
        var result: [String] = []
        result.reserveCapacity(uniqueCurrent.count)

        for key in savedOrder where currentSet.contains(key) {
            if emitted.insert(key).inserted {
                result.append(key)
            }
        }
        for key in uniqueCurrent where !emitted.contains(key) {
            emitted.insert(key)
            result.append(key)
        }
        return result
    }

    /// 寫：以已存陣列為基底，先把新出現的 key 補在最後，再只重排「目前可見的 key」在陣列中佔的位置；
    /// 不可見（暫時隱藏／查不到）的 key 保留原本位置。
    static func mergeOrderForSave(savedOrder: [String], newVisibleOrder: [String]) -> [String] {
        var base: [String] = []
        var baseSet = Set<String>()
        for key in savedOrder where !key.isEmpty {
            if baseSet.insert(key).inserted {
                base.append(key)
            }
        }

        var visible: [String] = []
        var visibleSet = Set<String>()
        for key in newVisibleOrder where !key.isEmpty {
            if visibleSet.insert(key).inserted {
                visible.append(key)
            }
        }

        // 先把新出現的可見 key 補在基底最後，確保它們在基底中有對應槽位
        for key in visible where !baseSet.contains(key) {
            baseSet.insert(key)
            base.append(key)
        }

        // 只重排可見 key 在基底中佔的位置，其餘隱藏 key 維持原索引不動
        var nextVisibleIndex = 0
        for index in base.indices where visibleSet.contains(base[index]) {
            base[index] = visible[nextVisibleIndex]
            nextVisibleIndex += 1
        }
        return base
    }

    /// 把 `sourceKey` 拿掉，插在目標卡前或後；拖到自己或找不到時不動。
    static func move(key sourceKey: String, relativeTo targetKey: String, after: Bool, in visibleOrder: [String]) -> [String] {
        guard sourceKey != targetKey,
              let sourceIndex = visibleOrder.firstIndex(of: sourceKey),
              let originalTargetIndex = visibleOrder.firstIndex(of: targetKey) else {
            return visibleOrder
        }
        var updated = visibleOrder
        let moved = updated.remove(at: sourceIndex)
        let targetIndex = originalTargetIndex - (sourceIndex < originalTargetIndex ? 1 : 0)
        updated.insert(moved, at: targetIndex + (after ? 1 : 0))
        return updated
    }

    /// 套用拖曳落點（插在指定卡片之前／之後，或移到所有卡最後）。
    static func applyDrop(sourceKey: String, target: DropTarget, in visibleOrder: [String]) -> [String] {
        switch target {
        case .before(let targetKey):
            return move(key: sourceKey, relativeTo: targetKey, after: false, in: visibleOrder)
        case .after(let targetKey):
            return move(key: sourceKey, relativeTo: targetKey, after: true, in: visibleOrder)
        case .end:
            guard let sourceIndex = visibleOrder.firstIndex(of: sourceKey) else {
                return visibleOrder
            }
            var updated = visibleOrder
            let moved = updated.remove(at: sourceIndex)
            updated.append(moved)
            return updated
        }
    }

    /// 計算拖曳游標落點（座標系為 `"usage-card-grid"`）：
    /// - 游標在格子範圍外 → `nil`（取消）
    /// - 多欄瀑布流中游標在卡片左半／右半 → `.before`／`.after`
    /// - 單欄時以卡片上半／下半決定 `.before`／`.after`
    /// - 游標在所有可見卡下方（且仍在格子含底部容許區內）→ `.end`（移到最後）
    /// - 游標在卡片間縫隙或格子邊緣內 → 距離卡片邊界最近的卡（距離相同以中心距與原順序打破平手）
    static func dropTarget(
        at point: CGPoint,
        gridSize: CGSize,
        cardFrames: [String: CGRect],
        visibleOrder: [String],
        bottomMargin: CGFloat = 0
    ) -> DropTarget? {
        guard point.x.isFinite, point.y.isFinite,
              gridSize.width.isFinite, gridSize.height.isFinite,
              gridSize.width > 0, gridSize.height > 0 else {
            return nil
        }

        let allowedHeight = gridSize.height + max(0, bottomMargin.isFinite ? bottomMargin : 0)
        guard point.x >= 0, point.x <= gridSize.width,
              point.y >= 0, point.y <= allowedHeight else {
            return nil
        }

        let visibleFrames: [(key: String, frame: CGRect)] = visibleOrder.compactMap { key in
            guard let frame = cardFrames[key], frame.width > 0, frame.height > 0 else { return nil }
            return (key, frame)
        }
        guard !visibleFrames.isEmpty else { return nil }

        // 1. 游標在某張卡內
        for item in visibleFrames {
            if point.x >= item.frame.minX, point.x <= item.frame.maxX,
               point.y >= item.frame.minY, point.y <= item.frame.maxY {
                let isMultiColumn = Set(visibleFrames.map { Int(($0.frame.minX * 100).rounded()) }).count > 1
                let after = isMultiColumn ? point.x >= item.frame.midX : point.y >= item.frame.midY
                return after ? .after(item.key) : .before(item.key)
            }
        }

        // 2. 在所有卡下方 → 移到最後
        let maxBottom = visibleFrames.map { $0.frame.maxY }.max() ?? 0
        if point.y > maxBottom {
            return .end
        }

        // 3. 在縫隙或格子邊緣內 → 距離最近的卡
        var bestKey: String?
        var bestEdgeDistSq = CGFloat.greatestFiniteMagnitude
        var bestCenterDistSq = CGFloat.greatestFiniteMagnitude
        for item in visibleFrames {
            let r = item.frame
            let dx = max(r.minX - point.x, 0, point.x - r.maxX)
            let dy = max(r.minY - point.y, 0, point.y - r.maxY)
            let edgeDistSq = dx * dx + dy * dy
            let cdx = r.midX - point.x
            let cdy = r.midY - point.y
            let centerDistSq = cdx * cdx + cdy * cdy
            if edgeDistSq < bestEdgeDistSq - 0.0001
                || (abs(edgeDistSq - bestEdgeDistSq) <= 0.0001 && centerDistSq < bestCenterDistSq - 0.0001) {
                bestEdgeDistSq = edgeDistSq
                bestCenterDistSq = centerDistSq
                bestKey = item.key
            }
        }
        guard let bestKey, let frame = cardFrames[bestKey] else { return nil }
        let isMultiColumn = Set(visibleFrames.map { Int(($0.frame.minX * 100).rounded()) }).count > 1
        let after = isMultiColumn ? point.x >= frame.midX : point.y >= frame.midY
        return after ? .after(bestKey) : .before(bestKey)
    }
}

/// F12 面板卡片順序的可觀察狀態；手勢放開與 `--usage-panel-move` 共用同一套移動與存檔入口。
final class UsageCardOrderStore: ObservableObject {
    static let shared = UsageCardOrderStore()

    private let defaults: UserDefaults
    @Published private(set) var savedOrder: [String]

    init(defaults: UserDefaults = appDefaults) {
        self.defaults = defaults
        self.savedOrder = UsageCardOrder.loadSavedOrder(from: defaults)
    }

    func reload() {
        let latest = UsageCardOrder.loadSavedOrder(from: defaults)
        if latest != savedOrder {
            savedOrder = latest
        }
    }

    func orderedKeys(for currentKeys: [String]) -> [String] {
        UsageCardOrder.orderedKeys(currentKeys: currentKeys, savedOrder: savedOrder)
    }

    /// 唯一共用的「移動卡片並存檔」函式（拖曳手勢與 `--usage-panel-move` 都走這裡）。
    @discardableResult
    func moveCard(sourceKey: String, target: UsageCardOrder.DropTarget, visibleKeys: [String]) -> Bool {
        let currentVisible = orderedKeys(for: visibleKeys)
        let nextVisible = UsageCardOrder.applyDrop(sourceKey: sourceKey, target: target, in: currentVisible)
        guard nextVisible != currentVisible else { return false }
        let latestSaved = UsageCardOrder.loadSavedOrder(from: defaults)
        let merged = UsageCardOrder.mergeOrderForSave(savedOrder: latestSaved, newVisibleOrder: nextVisible)
        UsageCardOrder.saveOrder(merged, to: defaults)
        savedOrder = merged
        return true
    }

    /// 插到目標卡之前（舊格式 `--usage-panel-move A:B` 用；手勢走 `.before`／`.after`）。
    @discardableResult
    func moveCard(from sourceKey: String, to targetKey: String, visibleKeys: [String]) -> Bool {
        moveCard(sourceKey: sourceKey, target: .before(targetKey), visibleKeys: visibleKeys)
    }
}
