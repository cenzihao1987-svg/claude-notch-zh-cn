import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"

    static let defaultsKey = "appLanguage"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chinese: "中文"
        case .english: "English"
        }
    }

    func text(_ chinese: String, _ english: String) -> String {
        self == .chinese ? chinese : english
    }

    static var saved: AppLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: defaultsKey) else {
            return .chinese
        }
        return AppLanguage(rawValue: rawValue) ?? .chinese
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}
