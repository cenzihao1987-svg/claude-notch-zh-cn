import Foundation

public enum CodexWidgetLanguage: String, Codable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"
}

public struct CodexWidgetSnapshot: Codable, Equatable, Sendable {
    public let remainingFraction: Double
    public let resetsAt: Date?
    public let fetchedAt: Date

    public init(remainingFraction: Double, resetsAt: Date?, fetchedAt: Date) {
        self.remainingFraction = min(1, max(0, remainingFraction))
        self.resetsAt = resetsAt
        self.fetchedAt = fetchedAt
    }

    public static var preview: Self {
        Self(
            remainingFraction: 0.72,
            resetsAt: Calendar.current.date(byAdding: .day, value: 7, to: Date()),
            fetchedAt: Date()
        )
    }
}

public enum CodexWidgetSnapshotStore {
    public static let suiteName = "group.com.claudenotch.app"
    private static let snapshotKey = "codex-weekly-snapshot"
    private static let languageKey = "app-language"

    public static func save(_ snapshot: CodexWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot),
              let defaults = UserDefaults(suiteName: suiteName)
        else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    public static func load() -> CodexWidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: snapshotKey)
        else { return nil }
        return try? JSONDecoder().decode(CodexWidgetSnapshot.self, from: data)
    }

    public static func saveLanguage(_ language: CodexWidgetLanguage) {
        UserDefaults(suiteName: suiteName)?.set(language.rawValue, forKey: languageKey)
    }

    public static func loadLanguage() -> CodexWidgetLanguage {
        guard let rawValue = UserDefaults(suiteName: suiteName)?.string(forKey: languageKey)
        else { return .chinese }
        return CodexWidgetLanguage(rawValue: rawValue) ?? .chinese
    }
}
