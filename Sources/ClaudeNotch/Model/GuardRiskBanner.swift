import Foundation

/// Whether the running Claude actually uses the dedicated launch profile.
enum GuardProtectionState: Equatable, Sendable {
    /// The running instance's arguments match the enabled profile.
    case protected
    /// The profile is ready; the next launch from the notch is protected.
    case ready
    /// The profile is off and Claude is not running.
    case off
    /// Not installed, profile incomplete, or the launch arguments could not be read.
    case unknown
    /// The profile is on, but this instance was opened elsewhere (Dock, Spotlight…) or several run.
    case notFromNotch(instances: Int)
    /// This tool launched the instance, but the profile changed afterwards (e.g. IP-following).
    case profileChanged
    /// The profile is off while Claude runs.
    case profileOff

    var isUnprotectedRun: Bool {
        switch self {
        case .notFromNotch, .profileChanged, .profileOff: true
        default: false
        }
    }

    static func evaluate(profile: GuardProfile, client: GuardClient?, receipt: LaunchReceipt?) -> Self {
        guard let client else { return .unknown }
        guard client.pid != nil else { return profile.enabled && profile.isValid ? .ready : .off }
        guard profile.enabled else { return .profileOff }
        guard profile.isValid else { return .unknown }
        if client.runningInstanceCount > 1 { return .notFromNotch(instances: client.runningInstanceCount) }
        guard let process = client.process else { return .unknown }
        if process.matches(profile) { return .protected }
        return receipt?.matches(client) == true ? .profileChanged : .notFromNotch(instances: 1)
    }
}

/// One actionable line in the bottom risk banner.
struct GuardRiskItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case protection(GuardProtectionState)
        case clash(GuardClashState)
        case exitUnknown
        case ipChanged(GuardExitChange)
        case geography
    }
    enum Action: Equatable, Sendable { case relaunch, openClash, recheck, confirmExit, details }

    let id: String
    let kind: Kind

    var isNetwork: Bool {
        if case .protection = kind { return false }
        return true
    }

    var action: Action {
        switch kind {
        case .protection: .relaunch
        case .clash(let state): state == .unknown ? .recheck : .openClash
        case .exitUnknown: .recheck
        case .ipChanged: .confirmExit
        case .geography: .details
        }
    }
}

/// Display state of the risk banner: pending → checking → resolved, then an all-clear.
/// Pure and clock-free so the timing rules are testable; the service drives `now`.
struct GuardRiskBannerState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case pending
        case checking(until: Date)
        case resolved(at: Date)
    }
    struct Row: Identifiable, Equatable, Sendable {
        let item: GuardRiskItem
        var phase: Phase
        var id: String { item.id }
        var isOpen: Bool {
            if case .resolved = phase { return false }
            return true
        }
    }

    static let resolvedDuration: TimeInterval = 3
    static let allClearDuration: TimeInterval = 4

    private(set) var rows: [Row] = []
    private(set) var allClearAt: Date?
    /// Items fixed during the current episode, for the all-clear summary.
    private(set) var resolvedItems: [GuardRiskItem] = []
    private var ignored = Set<String>()

    var isEmpty: Bool { rows.isEmpty && allClearAt == nil }
    var openCount: Int { rows.filter(\.isOpen).count }
    var showsResolvedRows: Bool { rows.contains { !$0.isOpen } }
    var hasNetworkRows: Bool { rows.contains { $0.item.isNetwork } }

    /// `resolvable` says whether an item that disappeared was actually fixed. When monitoring
    /// stopped (e.g. Claude quit), disappearing items are dropped without a resolved mark.
    mutating func reconcile(_ current: [GuardRiskItem], resolvable: (GuardRiskItem) -> Bool, now: Date) {
        let visible = current.filter { !ignored.contains($0.id) }
        if let start = allClearAt {
            if !visible.isEmpty || now.timeIntervalSince(start) >= Self.allClearDuration {
                allClearAt = nil
                resolvedItems = []
            }
        }
        let live = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [Row] = []
        for row in rows {
            if let item = live[row.id] {
                var phase = row.phase
                switch phase {
                case .resolved: phase = .pending
                case .checking(let until) where now >= until: phase = .pending
                default: break
                }
                next.append(.init(item: item, phase: phase))
            } else if ignored.contains(row.id) {
                continue
            } else if case .resolved(let at) = row.phase {
                if now.timeIntervalSince(at) < Self.resolvedDuration { next.append(row) }
            } else if resolvable(row.item) {
                next.append(.init(item: row.item, phase: .resolved(at: now)))
                resolvedItems.append(row.item)
            } else if case .checking(let until) = row.phase, now < until {
                next.append(row)
            }
        }
        for item in visible where !next.contains(where: { $0.id == item.id }) {
            next.append(.init(item: item, phase: .pending))
        }
        ignored.formIntersection(current.map(\.id))
        if visible.isEmpty, !next.contains(where: \.isOpen), !resolvedItems.isEmpty, rows.contains(where: \.isOpen) {
            // The last open item was just fixed: the whole banner turns green instead.
            allClearAt = now
            next = []
        } else if next.isEmpty, allClearAt == nil {
            resolvedItems = []
        }
        rows = next
    }

    mutating func markChecking(_ id: String, until: Date) {
        guard let index = rows.firstIndex(where: { $0.id == id }), rows[index].isOpen else { return }
        rows[index].phase = .checking(until: until)
    }

    /// Ends an explicit check (e.g. a finished recheck or a cancelled restart).
    mutating func settle(_ id: String, isCurrent: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == id }), case .checking = rows[index].phase else { return }
        if isCurrent { rows[index].phase = .pending } else { rows.remove(at: index) }
    }

    mutating func ignore(_ id: String) {
        ignored.insert(id)
        rows.removeAll { $0.id == id }
        if rows.isEmpty { resolvedItems = [] }
    }

    /// The next moment a row or the all-clear must change without any new input.
    var nextDeadline: Date? {
        var dates = rows.compactMap { row -> Date? in
            switch row.phase {
            case .pending: nil
            case .checking(let until): until
            case .resolved(let at): at.addingTimeInterval(Self.resolvedDuration)
            }
        }
        if let start = allClearAt { dates.append(start.addingTimeInterval(Self.allClearDuration)) }
        return dates.min()
    }
}
