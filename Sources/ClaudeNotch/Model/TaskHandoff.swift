import Foundation

enum HandoffDestination: String, CaseIterable, Equatable, Hashable, Sendable {
    case claudeDesktop
    case codex
    case workBuddy

    var agentName: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .codex: "Codex"
        case .workBuddy: "WorkBuddy"
        }
    }

    func menuLabel(language: AppLanguage) -> String {
        switch self {
        case .claudeDesktop: language.text("交给 Claude", "To Claude")
        case .codex: language.text("交给 Codex", "To Codex")
        case .workBuddy: language.text("交给 WorkBuddy", "To WorkBuddy")
        }
    }

    func openedMessage(language: AppLanguage) -> String {
        switch self {
        case .claudeDesktop:
            language.text("已交给 Claude 桌面端", "Handed off to Claude Desktop")
        case .codex:
            language.text("已交给 Codex", "Handed off to Codex")
        case .workBuddy:
            language.text("已打开 WorkBuddy，请检查后发送", "WorkBuddy opened; review and send")
        }
    }
}

struct AgentTaskReference: Equatable, Sendable, Identifiable {
    let provider: UsageProviderID
    let sessionID: String
    let title: String
    let cwd: String
    var workspaceRoots: [String] = []
    let transcriptPath: String?

    var id: String { "\(provider.rawValue):\(sessionID)" }

    var handoffDestinations: [HandoffDestination] {
        switch provider {
        case .claude: [.codex, .workBuddy]
        case .codex: [.claudeDesktop, .workBuddy]
        case .workbuddy: [.claudeDesktop, .codex]
        case .deepseek: []
        }
    }
}

struct TaskHandoffPacketV1: Codable, Equatable, Sendable {
    let version: Int
    let id: String
    let createdAt: Date
    let sourceAgent: String
    let targetAgent: String
    let taskTitle: String
    let sessionID: String
    let cwd: String
    let workspaceRoots: [String]
    let latestUserGoal: String?
    let recentAgentProgress: String?
    let gitBranch: String?
    let changedFiles: [String]
    let untrackedFiles: [String]
    let validationResults: [String]
    let awaitingConfirmation: Bool
    let unansweredConfirmation: String?
    let transcriptPath: String?
}

enum HandoffResult: Equatable, Sendable {
    case opened(destination: HandoffDestination, packetPath: String, instruction: String)
    case fallback(destination: HandoffDestination, packetPath: String, instruction: String,
                  reason: String)
    case failed(packetPath: String?, instruction: String?, reason: String)
}

enum HandoffStatus: Equatable, Sendable {
    case preparing
    case opened(String)
    case fallback(String)
    case failed(String)

    var message: String {
        switch self {
        case .preparing: "正在整理…"
        case let .opened(message), let .fallback(message), let .failed(message): message
        }
    }
}

struct HandoffTranscriptContext: Equatable, Sendable {
    var latestUserGoal: String?
    var recentAgentProgress: String?
    var validationResults: [String] = []
}

struct HandoffWorkspaceState: Equatable, Sendable {
    var gitBranch: String?
    var changedFiles: [String] = []
    var untrackedFiles: [String] = []
}
