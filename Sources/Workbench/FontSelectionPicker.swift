import AppKit
import SwiftUI

struct FontChoice: Hashable, Identifiable {
    let postScriptName: String
    let title: String
    let family: String
    let isMonospaced: Bool
    let lowercasedSearchName: String

    init(postScriptName: String, title: String, family: String, isMonospaced: Bool) {
        self.postScriptName = postScriptName
        self.title = title
        self.family = family
        self.isMonospaced = isMonospaced
        lowercasedSearchName = "\(title) \(family) \(postScriptName)".lowercased()
    }

    var id: String { postScriptName }
}

enum FontSelectionKind: Equatable {
    case interface
    case terminal
}

/// 查詢只在使用者打開選單，或測試探針明確要求時進行。
enum FontChoiceCatalog {
    static let terminalSystemPostScriptName = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).fontName
    private static let cachedInterfaceChoices = makeInterfaceChoices()
    private static let cachedTerminalChoices = makeTerminalChoices()

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isBlank(_ value: String) -> Bool {
        trimmed(value).isEmpty
    }

    static func systemOptionTitle(for kind: FontSelectionKind) -> String {
        switch kind {
        case .interface: return L("系統字型")
        case .terminal: return L("系統等寬字型")
        }
    }

    static func choices(for kind: FontSelectionKind) -> [FontChoice] {
        switch kind {
        case .interface:
            return interfaceChoices()
        case .terminal:
            return terminalChoices()
        }
    }

    static func interfaceChoices() -> [FontChoice] {
        cachedInterfaceChoices
    }

    private static func makeInterfaceChoices() -> [FontChoice] {
        let manager = NSFontManager.shared
        var seen = Set<String>()
        return manager.availableFontFamilies.compactMap { family in
            guard let font = manager.font(withFamily: family, traits: [], weight: 5, size: 13),
                  seen.insert(font.fontName).inserted else { return nil }
            return FontChoice(postScriptName: font.fontName, title: family, family: family, isMonospaced: font.isFixedPitch)
        }.sorted { $0.family.localizedStandardCompare($1.family) == .orderedAscending }
    }

    static func terminalChoices() -> [FontChoice] {
        cachedTerminalChoices
    }

    private static func makeTerminalChoices() -> [FontChoice] {
        let systemName = terminalSystemPostScriptName
        var seen = Set<String>()
        return NSFontManager.shared.availableFonts.compactMap { postScriptName in
            guard postScriptName != systemName, seen.insert(postScriptName).inserted,
                  let font = NSFont(name: postScriptName, size: 13), font.isFixedPitch else { return nil }
            let family = font.familyName ?? postScriptName
            let title = family == postScriptName ? postScriptName : "\(family) · \(postScriptName)"
            return FontChoice(postScriptName: postScriptName, title: title, family: family, isMonospaced: true)
        }.sorted {
            let familyOrder = $0.family.localizedStandardCompare($1.family)
            return familyOrder == .orderedSame
                ? $0.postScriptName.localizedStandardCompare($1.postScriptName) == .orderedAscending
                : familyOrder == .orderedAscending
        }
    }

    static func title(for postScriptName: String, kind: FontSelectionKind, choices: [FontChoice]) -> String {
        switch kind {
        case .interface where isBlank(postScriptName):
            return systemOptionTitle(for: .interface)
        case .terminal where postScriptName == terminalSystemPostScriptName:
            return systemOptionTitle(for: .terminal)
        default:
            if let choice = choices.first(where: { $0.postScriptName == postScriptName }) { return choice.title }
            guard let font = NSFont(name: postScriptName, size: 13) else { return postScriptName }
            return "\(font.familyName ?? postScriptName) · \(postScriptName)"
        }
    }

    static func containsCilantroOrNiYu(_ choices: [FontChoice]) -> (cilantro: Bool, niYu: Bool) {
        let names = choices.map { "\($0.postScriptName) \($0.family)".lowercased() }
        return (
            names.contains { $0.contains("cilantro") || $0.contains("香菜") },
            names.contains { $0.contains("niyu") || $0.contains("逆雨") }
        )
    }
}

struct FontSelectionPicker: View {
    @Binding var selection: String
    let kind: FontSelectionKind

    @State private var isPresented = false
    @State private var search = ""
    @State private var choices: [FontChoice]?

    private var systemValue: String {
        switch kind {
        case .interface: return ""
        case .terminal: return FontChoiceCatalog.terminalSystemPostScriptName
        }
    }

    private var selectedTitle: String {
        FontChoiceCatalog.title(for: selection, kind: kind, choices: choices ?? [])
    }

    private var filteredChoices: [FontChoice] {
        let values = choices ?? []
        let query = FontChoiceCatalog.trimmed(search).lowercased()
        guard !query.isEmpty else { return values }
        return values.filter { $0.lowercasedSearchName.contains(query) }
    }

    private var currentValueChoice: FontChoice? {
        guard !FontChoiceCatalog.isBlank(selection), selection != systemValue,
              !(choices ?? []).contains(where: { $0.postScriptName == selection }) else { return nil }
        let font = NSFont(name: selection, size: 13)
        return FontChoice(
            postScriptName: selection,
            title: "\(L("目前值")) · \(font?.familyName ?? selection) · \(selection)",
            family: font?.familyName ?? selection,
            isMonospaced: font?.isFixedPitch ?? false
        )
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Text(selectedTitle).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(L("搜尋字型"), text: $search)
                    .textFieldStyle(.roundedBorder)
                Text("\(L("目前選擇："))\(selectedTitle)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        choiceRow(postScriptName: systemValue, title: FontChoiceCatalog.systemOptionTitle(for: kind))
                        if let currentValueChoice {
                            choiceRow(postScriptName: currentValueChoice.postScriptName, title: currentValueChoice.title)
                            Divider()
                        }
                        ForEach(filteredChoices) { choice in
                            choiceRow(postScriptName: choice.postScriptName, title: choice.title)
                        }
                        if filteredChoices.isEmpty {
                            Text(L("沒有符合的字型"))
                                .font(.callout).foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 360, height: 390)
        }
    }

    private func open() {
        if choices == nil { choices = FontChoiceCatalog.choices(for: kind) }
        search = ""
        isPresented = true
    }

    @ViewBuilder
    private func choiceRow(postScriptName: String, title: String) -> some View {
        Button {
            selection = postScriptName
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if selection == postScriptName { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}
