import Foundation

enum GuardClashState: String, Equatable, Sendable {
    case global, rule, direct, notRunning, unknown
    func label(_ language: AppLanguage) -> String {
        switch self {
        case .global: language.text("全局模式", "Global mode")
        case .rule: language.text("规则模式", "Rule mode")
        case .direct: language.text("直连模式", "Direct mode")
        case .notRunning: language.text("未运行", "Not running")
        case .unknown: language.text("无法核验", "Unverified")
        }
    }
}

struct GuardConnectionIssue: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable { case ipChanged, clash, exitUnknown }
    let id: String
    let kind: Kind
    let change: GuardExitChange?
    let clash: GuardClashState?
    func message(_ language: AppLanguage) -> String {
        switch kind {
        case .ipChanged: language.text("公网出口 IP 已变化，请确认当前线路。", "The public exit IP changed. Check the current route.")
        case .clash:
            language.text("Clash Verge：\(clash?.label(language) ?? "无法核验")，请检查全局模式。",
                          "Clash Verge: \(clash?.label(language) ?? "Unverified"). Check global mode.")
        case .exitUnknown: language.text("当前出口无法确认，请重新检查。", "The current exit could not be verified. Check again.")
        }
    }
}

/// Warning state never contributes points to the geographic risk evaluator.
struct GuardConnectionMonitor: Sendable {
    var baselines: [String: GuardExit] = [:]
    private(set) var active = false
    private(set) var clash: GuardClashState?
    private(set) var checkedAt: Date?
    private(set) var candidates: [String: GuardExit] = [:]
    private var changes: [String: GuardExitChange] = [:]
    private var exitUnknown = false
    private var ignored = Set<String>()
    private var delivered = Set<String>()

    init(baselines: [String: GuardExit] = [:]) { self.baselines = baselines }

    var issues: [GuardConnectionIssue] {
        guard active else { return [] }
        var result = changes.keys.sorted().compactMap { family -> GuardConnectionIssue? in
            guard let change = changes[family] else { return nil }
            return .init(id: "ip-\(family)-\(change.previous.ip)-\(change.current.ip)", kind: .ipChanged, change: change, clash: nil)
        }
        if let clash, clash != .global { result.append(.init(id: "clash-\(clash.rawValue)", kind: .clash, change: nil, clash: clash)) }
        if exitUnknown { result.append(.init(id: "exit-unknown", kind: .exitUnknown, change: nil, clash: nil)) }
        return result
    }
    var visibleIssues: [GuardConnectionIssue] { issues.filter { !ignored.contains($0.id) } }

    mutating func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        candidates = [:]; changes = [:]; ignored = []; delivered = []; exitUnknown = false
        clash = nil
    }
    mutating func observeClash(_ state: GuardClashState, at date: Date) {
        clash = state; checkedAt = date
        reconcile()
    }
    mutating func observe(_ exit: GuardExit) {
        checkedAt = exit.observedAt; exitUnknown = false
        guard active else { return }
        let family = GuardNetworkTracker.family(exit)
        guard let previous = baselines[family] else {
            baselines[family] = exit; reconcile(); return
        }
        guard previous.ip != exit.ip else { candidates[family] = nil; reconcile(); return }
        if let candidate = candidates[family], candidate.ip == exit.ip {
            let elapsed = exit.observedAt.timeIntervalSince(candidate.observedAt)
            if (5...45).contains(elapsed) {
                changes[family] = .init(id: UUID(), previous: previous, current: exit)
                baselines[family] = exit; candidates[family] = nil
            } else if elapsed > 45 || elapsed < 0 { candidates[family] = exit }
        } else { candidates[family] = exit }
        reconcile()
    }
    mutating func failedExit() { exitUnknown = true; candidates = [:]; reconcile() }
    mutating func invalidateCandidates() { candidates = [:] }
    mutating func acknowledge() { ignored.formUnion(issues.map(\.id)) }
    /// Hides one warning; the others stay visible.
    mutating func acknowledge(_ id: String) {
        if issues.contains(where: { $0.id == id }) { ignored.insert(id) }
    }
    mutating func confirmExit() { changes = [:]; candidates = [:]; reconcile() }
    mutating func acceptLaunch(_ exit: GuardExit?) {
        if let exit { baselines[GuardNetworkTracker.family(exit)] = exit }
    }
    mutating func takeNewNotice() -> [GuardConnectionIssue] {
        let fresh = visibleIssues.filter { !delivered.contains($0.id) }
        delivered.formUnion(fresh.map(\.id))
        return fresh
    }
    private mutating func reconcile() {
        let current = Set(issues.map(\.id))
        ignored.formIntersection(current); delivered.formIntersection(current)
    }
}

struct GuardLaunchNetworkSample: Sendable {
    let exit: GuardExit?
    let clash: GuardClashState
    var fingerprint: String { "\(exit?.ip ?? "unknown")|\(clash.rawValue)" }
    func issues(baselines: [String: GuardExit]) -> [GuardConnectionIssue] {
        var monitor = GuardConnectionMonitor(baselines: baselines)
        monitor.setActive(true)
        monitor.observeClash(clash, at: .now)
        guard let exit else { monitor.failedExit(); return monitor.issues }
        // Preflight compares immediately; the coordinator separately confirms changed exits twice.
        monitor.observe(exit)
        if let old = baselines[GuardNetworkTracker.family(exit)], old.ip != exit.ip {
            return [.init(id: "launch-ip", kind: .ipChanged,
                          change: .init(id: UUID(), previous: old, current: exit), clash: nil)] + monitor.issues
        }
        return monitor.issues
    }
}

enum GuardLaunchNetworkError: LocalizedError {
    case unstable
    var errorDescription: String? { "网络状态反复改变，已停止启动，请稳定线路后重试。 / The network kept changing; launch was stopped." }
}

@MainActor
enum GuardLaunchNetworkGate {
    /// Returns nil for ordinary cancellation. No process is touched by this coordinator.
    static func authorize(baselines: [String: GuardExit], approved: String? = nil,
                          sample: () async -> GuardLaunchNetworkSample,
                          confirm: (GuardLaunchNetworkSample, [GuardConnectionIssue]) async -> Bool,
                          wait: () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }) async throws -> GuardLaunchNetworkSample? {
        var current = await sample()
        try Task.checkCancellation()
        if current.fingerprint == approved { return current }
        if let exit = current.exit, let old = baselines[GuardNetworkTracker.family(exit)], old.ip != exit.ip {
            try await wait()
            let repeated = await sample()
            guard repeated.exit?.ip == current.exit?.ip else { throw GuardLaunchNetworkError.unstable }
            current = repeated
        }
        for _ in 0..<3 {
            try Task.checkCancellation()
            let issues = current.issues(baselines: baselines)
            if issues.isEmpty || current.fingerprint == approved { return current }
            guard await confirm(current, issues) else { return nil }
            try Task.checkCancellation()
            let latest = await sample()
            try Task.checkCancellation()
            if latest.fingerprint == current.fingerprint { return latest }
            current = latest
        }
        throw GuardLaunchNetworkError.unstable
    }
}
