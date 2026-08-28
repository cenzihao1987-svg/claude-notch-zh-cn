import Foundation

struct AgentTaskReference: Equatable, Sendable, Identifiable {
    let provider: UsageProviderID
    let sessionID: String
    let title: String
    let cwd: String
    var workspaceRoots: [String] = []
    let transcriptPath: String?

    var id: String { "\(provider.rawValue):\(sessionID)" }

    var destination: UsageProviderID {
        provider == .codex ? .claude : .codex
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
    case opened(destination: UsageProviderID, packetPath: String, instruction: String)
    case fallback(destination: UsageProviderID, packetPath: String, instruction: String,
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
