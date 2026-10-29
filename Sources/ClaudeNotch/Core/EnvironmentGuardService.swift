import AppKit
import Darwin
import Foundation
import Network
import Observation
import Security

/// Reads only the launch-setting whitelist. No account data or complete environment is retained.
enum GuardProcessReader {
    static func read(pid: Int32) -> GuardProcessConfiguration? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 2_097_152 else { return nil }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { bytes in
            sysctl(&mib, u_int(mib.count), bytes.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        return parse(data.prefix(size))
    }

    static func proxyEnvironment(pid: Int32) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 4, size <= 2_097_152 else { return nil }
        var data = Data(count: size)
        guard data.withUnsafeMutableBytes({ sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }) == 0 else { return nil }
        return parseProxyEnvironment(data.prefix(size))
    }

    static func parseProxyEnvironment(_ data: Data) -> [String: String]? {
        guard data.count > 4 else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 65_536 else { return nil }
        let bytes = Array(data); var cursor = 4
        func token() -> ArraySlice<UInt8>? {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            let value = bytes[cursor..<end]; cursor = end + 1; return value
        }
        guard token() != nil else { return nil }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        for _ in 0..<argc { guard token() != nil else { return nil } }
        var result: [String: String] = [:]
        while let raw = token() {
            guard let equal = raw.firstIndex(of: 61), equal - raw.startIndex <= 16 else { continue }
            let key = String(decoding: raw[..<equal], as: UTF8.self)
            guard GuardExecutionInspector.proxyKeys.contains(key.lowercased()), raw.count <= 4096 else { continue }
            result[key] = String(decoding: raw[raw.index(after: equal)...], as: UTF8.self)
        }
        return result
    }

    static func parse(_ data: Data) -> GuardProcessConfiguration? {
        guard data.count > 4 else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 65_536 else { return nil }
        let bytes = Array(data)
        var cursor = 4
        func token() -> ArraySlice<UInt8>? {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            let value = bytes[cursor..<end]
            cursor = end + 1
            return value
        }
        guard token() != nil else { return nil } // executable path, followed by padding
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var result = GuardProcessConfiguration()
        var pending: String?
        for _ in 0..<argc {
            guard let raw = token() else { return nil }
            // Decode only the recognized arguments and values immediately following them.
            if let field = pending {
                let value = String(decoding: raw, as: UTF8.self)
                if field == "-AppleLanguages" { result.appleLanguages = value }
                if field == "-AppleLocale" { result.locale = value }
                pending = nil
            } else if raw.starts(with: Array("--lang=".utf8)) {
                result.language = String(decoding: raw.dropFirst(7), as: UTF8.self)
            } else if raw.elementsEqual(Array("-AppleLanguages".utf8)) { pending = "-AppleLanguages" }
            else if raw.elementsEqual(Array("-AppleLocale".utf8)) { pending = "-AppleLocale" }
        }
        while cursor < bytes.count {
            guard let raw = token() else { break }
            if raw.starts(with: [84, 90, 61]) { result.timeZone = String(decoding: raw.dropFirst(3), as: UTF8.self) }
        }
        return result
    }
}

actor GuardSignatureInspector {
    private var cache: (key: String, value: GuardSignature)?

    func inspect(path: String, version: String, force: Bool) -> GuardSignature {
        let url = URL(fileURLWithPath: path)
        let executable = Bundle(url: url)?.executableURL
        let files = [url.appendingPathComponent("Contents/Info.plist"),
                     url.appendingPathComponent("Contents/Resources/app.asar"),
                     url.appendingPathComponent("Contents/_CodeSignature/CodeResources")] + [executable].compactMap { $0 }
        let stamps = files.map { file -> String in
            let a = try? FileManager.default.attributesOfItem(atPath: file.path)
            return "\(file.path):\(a?[.modificationDate] ?? "-"):\(a?[.size] ?? "-")"
        }.joined(separator: "|")
        let key = "\(path)|\(version)|\(stamps)"
        if !force, let cache, cache.key == key { return cache.value }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return .unavailable }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else {
            return status == errSecSuccess ? .unavailable : .invalid(code: status)
        }
        let result: GuardSignature
        let signatureFlags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if status != errSecSuccess { result = .invalid(code: status) }
        else if signatureFlags & 0x2 != 0 { result = .local }
        else if let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String {
            result = .valid(publisher: team)
        } else { result = .unavailable }
        cache = (key, result)
        return result
    }
}

enum GuardLaunchError: LocalizedError {
    case notInstalled, invalidProfile, alreadyRunning, locationUnavailable

    var errorDescription: String? {
        switch self {
        case .notInstalled: "未找到 Claude Desktop / Claude Desktop not found"
        case .invalidProfile: "请先选择有效的地区和时区 / Choose a valid region and timezone"
        case .alreadyRunning: "请先正常退出 Claude，再按配置启动 / Quit Claude normally before a configured launch"
        case .locationUnavailable: "出口地区或时区尚未取得，请重新检测或手动配置 / Check the route or choose a manual location first"
        }
    }
}

@MainActor
enum GuardLauncher {
    static let bundleIDs = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]

    static var runningApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { bundleIDs.contains($0.bundleIdentifier ?? "") }
    }

    static func configuration(profile: GuardProfile?, webSession: String? = nil) throws -> NSWorkspace.OpenConfiguration {
        let config = NSWorkspace.OpenConfiguration()
        config.allowsRunningApplicationSubstitution = false
        if let profile, profile.enabled {
            guard profile.isValid else { throw GuardLaunchError.invalidProfile }
            config.arguments = profile.arguments
            config.environment = profile.environment
            if let webSession {
                guard webSession.count == 32, webSession.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw GuardLaunchError.invalidProfile }
                config.environment[GuardWebEnvironmentReader.sessionKey] = webSession
            }
        }
        return config
    }

    static func installedURL(preferredPath: String? = nil) -> URL? {
        if let running = runningApplications.first?.bundleURL { return running }
        var candidates: [URL] = []
        if let preferredPath { candidates.append(URL(fileURLWithPath: preferredPath)) }
        candidates += bundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        candidates += [URL(fileURLWithPath: "/Applications/Claude.app"),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app")]
        return candidates.first { url in
            bundleIDs.contains(Bundle(url: url)?.bundleIdentifier ?? "") && FileManager.default.fileExists(atPath: url.path)
        }
    }

    static func version(at url: URL) -> String {
        // Bundle caches Info.plist values; read the file so an in-place update is observable.
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return "—" }
        return info["CFBundleShortVersionString"] as? String ?? "—"
    }
}

enum GuardRestartError: LocalizedError, Equatable {
    case refused, timedOut, profileChanged
    var errorDescription: String? {
        switch self {
        case .refused: "Claude 未同意退出，请正常退出后重试。 / Claude did not accept the quit request."
        case .timedOut: "Claude 尚未退出，已停止重启。请完成退出后重试。 / Claude is still running; restart was stopped."
        case .profileChanged: "专属配置状态已改变，已停止重启。 / The launch profile changed; restart was stopped."
        }
    }
}

/// Injectable exit/wait/launch boundaries allow timing tests without closing a user's Claude.
@MainActor
enum GuardRestartCoordinator {
    static func run(requestExit: () -> Bool, isRunning: () -> Bool,
                    launch: () async throws -> Void,
                    wait: (@MainActor () async throws -> Void)? = nil,
                    maxPolls: Int = 30) async throws {
        if isRunning() {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(15))
            guard requestExit() else { throw GuardRestartError.refused }
            for _ in 0..<maxPolls {
                try Task.checkCancellation()
                if !isRunning() { break }
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { throw GuardRestartError.timedOut }
                if let wait { try await wait() }
                else { try await Task.sleep(for: min(.milliseconds(500), remaining)) }
            }
            guard !isRunning() else { throw GuardRestartError.timedOut }
        }
        try Task.checkCancellation()
        try await launch()
    }
}

@MainActor @Observable
final class EnvironmentGuardService {
    static let shared = EnvironmentGuardService()
    static let profileKey = "environmentGuard.profile.v1"
    static let receiptKey = "environmentGuard.receipt.v1"
    private(set) var systemEnvironment = GuardSystemEnvironment.read()
    private(set) var profile: GuardProfile
    private(set) var snapshot = GuardSnapshot()
    private(set) var receipt: LaunchReceipt?
    private(set) var isChecking = false
    private(set) var isCheckingNetwork = false
    private(set) var isRechecking = false
    private(set) var isLaunching = false
    private(set) var isClosingClaude = false
    private(set) var windowVisible = false
    private(set) var networkChecksEnabled: Bool
    private(set) var operationMessage: GuardText?
    private(set) var operationFailed = false
    private(set) var isDesignPreview = false
    private(set) var networkTracker: GuardNetworkTracker
    private(set) var manualLocationOverride = false
    private(set) var historyError = false
    private(set) var networkNoticeGeneration = 0
    private(set) var exitLogRevision = 0
    private(set) var connectionMonitor = GuardConnectionMonitor()
    private(set) var isCheckingConnection = false
    static let welcomeKey = "environmentGuard.welcome.v1"
    private(set) var riskBanner = GuardRiskBannerState()
    /// Refreshed by `reconcileRiskBanner()`; layout reads it many times per second, so it is stored.
    private(set) var protectionState = GuardProtectionState.unknown
    private(set) var welcomeResolved = false
    private var ignoredProtectionInstance: String?
    @ObservationIgnored private var announcedProtectionInstance: String?
    @ObservationIgnored private var bannerTimer: Task<Void, Never>?
    @ObservationIgnored private var fastRecheckTask: Task<Void, Never>?
    @ObservationIgnored private var clashTimer: Timer?
    @ObservationIgnored private var clashTask: Task<Void, Never>?
    @ObservationIgnored private var clashGeneration = 0
    @ObservationIgnored private let clashProvider: @MainActor () async -> GuardClashState
    @ObservationIgnored private let launchNetworkSampler: @MainActor () async -> GuardLaunchNetworkSample
    @ObservationIgnored private let launchConfirmation: (@MainActor (GuardLaunchNetworkSample, [GuardConnectionIssue]) async -> Bool)?
    @ObservationIgnored private let notificationSender: @MainActor ([GuardConnectionIssue]) async -> Void
    @ObservationIgnored private let launchActions: GuardLaunchActions
    @ObservationIgnored private var notificationTask: Task<Void, Never>?
    @ObservationIgnored private var lastLoggedRisk: GuardLoggedRisk?
    @ObservationIgnored private let activityProvider: @MainActor () -> GuardDesktopActivity
    @ObservationIgnored private var activityRevision = 0
    @ObservationIgnored private var needsExposureRuleLog = false
    @ObservationIgnored private var previewLogEntries: [GuardNetworkLogEntry] = []
    private let historyStore: GuardHistoryStore
    private let historyReadFailed: Bool
    @ObservationIgnored private var exitRecheckTask: Task<Void, Never>?
    @ObservationIgnored private var lastJournaledByFamily: [String: GuardExit] = [:]
    @ObservationIgnored private var locationVerificationCache: [String: (Date, GuardGeoVerification)] = [:]
    var exitAlert: GuardExitChange? { snapshot.networkBehavior.change ?? networkTracker.alert }
    var followingIP: Bool { !manualLocationOverride }
    var hasNetworkWarning: Bool {
        hasGeographicWarning || !connectionMonitor.visibleIssues.isEmpty
    }
    var hasGeographicWarning: Bool { snapshot.networkBehavior.kind != nil && snapshot.networkBehavior.identifier != networkTracker.history.ignoredWarning }
    var canConfirmNewExit: Bool { exitAlert != nil && networkTracker.candidate == nil && snapshot.networkIsFresh(at: .now) }



    #if DEBUG
    func loadDesignPreview() { loadDesignPreview(running: false) }

    func loadDesignPreview(running: Bool, rechecking: Bool = false, networkWarning: Bool = false, ip: String = "203.0.113.25") {
        stop()
        isDesignPreview = true
        networkTracker = .init()
        connectionMonitor = .init()
        riskBanner = .init()
        protectionState = .unknown
        welcomeResolved = true
        ignoredProtectionInstance = nil
        announcedProtectionInstance = nil
        historyError = false
        manualLocationOverride = false
        isRechecking = rechecking
        snapshot.desktopActivity = running ? .active : .inactive
        systemEnvironment = .init(languageCode: "zh-CN", localeIdentifier: "zh_CN", timeZoneIdentifier: "Asia/Shanghai")
        profile = GuardProfile(enabled: true, languageCode: "en-US", localeIdentifier: "en_US", timeZoneIdentifier: "America/Los_Angeles")
        snapshot = GuardSnapshot(client: .init(path: "/Applications/Claude.app", version: "1.49585.0", pid: running ? Int32.max : nil,
                                               launchedAt: running ? .now : nil, signature: .local, runningInstanceCount: running ? 1 : 0), checkedAt: .now,
                                 network: .init(countryCode: "TR", fetchedAt: .now, city: "Istanbul", ip: GuardExit.normalizedIP(ip)), networkInvalidated: false)
        snapshot.desktopActivity = running ? .active : .inactive
        if networkWarning {
            let base = Date.now.addingTimeInterval(-120)
            for (ip, country, second) in [("203.0.113.1", "US", 0.0), ("203.0.113.2", "TR", 10.0),
                ("203.0.113.2", "TR", 15.0), ("203.0.113.3", "SG", 30.0), ("203.0.113.3", "SG", 35.0)] {
                networkTracker.observe(GuardExit(.init(countryCode: country, fetchedAt: base.addingTimeInterval(second), ip: ip), activity: .active)!, verification: .verified)
            }
            updateNetworkBehavior()
        }
        if running {
            snapshot.webEnvironment = .observed(.init(protocol: 1, session: "preview", pid: Int32.max,
                capturedAt: Date.now.timeIntervalSince1970 * 1000, candidateCount: 1, failedCount: 0,
                frames: [.init(context: "claude.ai", language: "en-US", languages: ["en-US"], locale: "en-US", timeZone: "America/Los_Angeles")]))
        }
    }
    func loadGuardDemo(_ scenario: GuardDemoScenario) {
        loadDesignPreview(running: true)
        let base = Date.now.addingTimeInterval(-120)
        let demoActivity: GuardDesktopActivity = scenario == .inactive || scenario == .welcome ? .inactive : .active
        let connectionScenario = [.sameCountry, .clashRule, .clashUnknown, .connectionCombined, .connectionHealthy, .unprotectedCombined].contains(scenario)
        if connectionScenario { connectionMonitor.setActive(true) }
        snapshot.desktopActivity = demoActivity
        if scenario == .inactive || scenario == .welcome, let client = snapshot.client {
            snapshot.client = .init(path: client.path, version: client.version, pid: nil, launchedAt: nil, signature: client.signature)
            snapshot.webEnvironment = .unavailable(.notRunning)
        }
        if scenario == .unprotectedLaunch || scenario == .unprotectedCombined, var client = snapshot.client {
            // Opened from the Dock: Claude runs without the profile's launch arguments.
            client.process = GuardProcessConfiguration()
            snapshot.client = client
        }
        if scenario == .welcome {
            profile.enabled = false
            welcomeResolved = false
        }
        func sample(_ ip: String, _ country: String, _ second: Double, _ verification: GuardGeoVerification = .verified) {
            let zone = country == "TR" ? "Europe/Istanbul" : country == "US" ? "America/Los_Angeles" : "Asia/Singapore"
            let observation = GuardNetworkObservation(countryCode: country, fetchedAt: base.addingTimeInterval(second), ip: ip, timeZone: zone)
            networkTracker.observe(GuardExit(observation, activity: demoActivity)!, verification: verification)
            if connectionScenario { connectionMonitor.observe(GuardExit(observation, activity: demoActivity)!) }
            snapshot.network = observation
        }
        let ipv6 = scenario == .longIPv6
        sample(ipv6 ? "2001:db8:1234:5678::1" : "203.0.113.1", "US", 0)
        if scenario == .sameCountry || scenario == .connectionCombined {
            for number in 2...5 {
                sample("203.0.113.\(number)", "US", Double(number * 10))
                sample("203.0.113.\(number)", "US", Double(number * 10 + 5))
            }
        } else if connectionScenario || [.unprotectedLaunch, .welcome].contains(scenario) {
            // Stable exit: the mode or the launch, rather than a fabricated geographic change, drives this case.
        } else if scenario == .dualStack {
            sample("2001:db8::1", "TR", 30)
        } else {
            sample(ipv6 ? "2001:db8:9876:5432::2" : "203.0.113.2", "TR", 10)
            sample(ipv6 ? "2001:db8:9876:5432::2" : "203.0.113.2", "TR", 15,
                   scenario == .unverified ? .conflict : .verified)
            if scenario == .repeated || scenario == .roundTrip || scenario == .longIPv6 || scenario == .inactive {
                let country = scenario == .roundTrip ? "US" : "SG"
                sample(ipv6 ? "2001:db8:abcd:ef01::3" : "203.0.113.3", country, 30)
                sample(ipv6 ? "2001:db8:abcd:ef01::3" : "203.0.113.3", country, 35)
            }
        }
        if let network = snapshot.network {
            profile.localeIdentifier = "en_" + network.countryCode
            profile.timeZoneIdentifier = network.timeZone ?? "Europe/Istanbul"
        }
        if connectionScenario {
            connectionMonitor.observeClash(scenario == .clashUnknown ? .unknown :
                ([.clashRule, .connectionCombined, .unprotectedCombined].contains(scenario) ? .rule : .global), at: .now)
        }
        updateNetworkBehavior()
        if let network = snapshot.network, let exit = GuardExit(network, activity: snapshot.desktopActivity) {
            if previewLogEntries.isEmpty, let baseline = networkTracker.history.lastLaunch {
                previewLogEntries.append(.init(recordID: UUID(), kind: "tool-start", exit: baseline,
                    recordedAt: base, risk: .init(systemTotal: 50, configuredTotal: 10, networkPoints: 0,
                        minimumTotal: 0, behavior: nil, locationUnverified: false, desktopActivity: demoActivity)))
            }
            if previewLogEntries.count == 1 {
                for event in (networkTracker.history.geographicTransitions ?? []).dropLast() {
                    previewLogEntries.append(.init(recordID: UUID(), kind: "exit-change", exit: event.current,
                        recordedAt: event.current.observedAt, previous: event.previous,
                        risk: .init(systemTotal: 80, configuredTotal: 50, networkPoints: 30, minimumTotal: 50,
                                    behavior: .anomalous, locationUnverified: false, desktopActivity: .active)))
                }
            }
            lastLoggedRisk = previewLogEntries.last?.risk
            appendExitLog(exit, kind: "exit-change", previous: snapshot.networkBehavior.change?.previous ?? networkTracker.history.lastLaunch)
        }
        networkNoticeGeneration += 1
    }
    func refreshGuardDemoClock() {
        guard isDesignPreview, let old = snapshot.network else { return }
        snapshot.network = .init(countryCode: old.countryCode, fetchedAt: .now, city: old.city,
            subdivision: old.subdivision, ip: old.ip, timeZone: old.timeZone)
        snapshot.checkedAt = .now
    }
    #endif

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let inspector = GuardSignatureInspector()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var periodicTimer: Timer?
    @ObservationIgnored private var webTimer: Timer?
    @ObservationIgnored private var webTask: Task<Void, Never>?
    @ObservationIgnored private var webGeneration = 0
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var localTask: Task<Void, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var networkGeneration = 0
    @ObservationIgnored private var pendingRefresh = false
    @ObservationIgnored private var pendingForce = false
    @ObservationIgnored private var preferredPath: String?
    @ObservationIgnored private var recheckGeneration = 0

    init(defaults: UserDefaults = .standard, historyStore: GuardHistoryStore = .standard,
         activityProvider: @escaping @MainActor () -> GuardDesktopActivity = GuardDesktopActivityReader.current,
         clashProvider: @escaping @MainActor () async -> GuardClashState = GuardClashReader.read,
         launchNetworkSampler: @escaping @MainActor () async -> GuardLaunchNetworkSample = GuardLaunchNetworkProbe.sample,
         launchConfirmation: (@MainActor (GuardLaunchNetworkSample, [GuardConnectionIssue]) async -> Bool)? = nil,
         notificationSender: @escaping @MainActor ([GuardConnectionIssue]) async -> Void = { await GuardNetworkNotifier.shared.send($0) },
         launchActions: GuardLaunchActions = .init()) {
        self.activityProvider = activityProvider
        self.clashProvider = clashProvider
        self.launchNetworkSampler = launchNetworkSampler
        self.launchConfirmation = launchConfirmation
        self.notificationSender = notificationSender
        self.launchActions = launchActions
        self.defaults = defaults
        self.historyStore = historyStore
        do {
            let history = try historyStore.load()
            networkTracker = .init(history: history); historyReadFailed = false
            needsExposureRuleLog = history.exposurePolicyVersion != 1
                && (!(history.geographicTransitions ?? []).isEmpty || history.incident != nil)
        }
        catch { networkTracker = .init(); historyReadFailed = true; historyError = true }
        var initialProfile = defaults.data(forKey: Self.profileKey).flatMap { try? JSONDecoder().decode(GuardProfile.self, from: $0) } ?? .init()
        if initialProfile.timeZoneOverrides != nil { initialProfile.timeZoneOverrides = [:] }
        profile = initialProfile
        receipt = defaults.data(forKey: Self.receiptKey).flatMap { try? JSONDecoder().decode(LaunchReceipt.self, from: $0) }
        networkChecksEnabled = defaults.object(forKey: "environmentGuard.networkChecksEnabled") as? Bool ?? true
        preferredPath = defaults.string(forKey: "environmentGuard.appPath")
        connectionMonitor = .init(baselines: networkTracker.history.connectionBaselines
            ?? (networkTracker.history.lastExposedByFamily ?? [:]).filter { $0.value.desktopActivity == .active })
        lastLoggedRisk = try? historyStore.readJournal(limit: 1).entries.first?.risk
        welcomeResolved = defaults.string(forKey: Self.welcomeKey) != nil
        observeRiskItems()
    }

    var findings: [GuardFinding] {
        GuardEvaluator.findings(profile: profile, snapshot: snapshot, networkEnabled: networkChecksEnabled) + extendedFindings
    }

    var issues: [GuardFinding] {
        var seen = Set<String>()
        return findings.filter { item in
            guard let id = item.actionID else { return false }
            return seen.insert(id).inserted
        }
    }

    var summary: GuardSummary { .init(findings: findings, checked: snapshot.checkedAt != nil) }

    var currentRisk: GuardRiskAssessment {
        GuardRiskEvaluator.assess(environment: systemEnvironment, snapshot: snapshot, networkEnabled: networkChecksEnabled)
    }

    var configuredRisk: GuardRiskAssessment {
        let environment = profile.isValid ? GuardSystemEnvironment(languageCode: profile.languageCode,
            localeIdentifier: profile.localeIdentifier, timeZoneIdentifier: profile.timeZoneIdentifier) : nil
        return GuardRiskEvaluator.assess(environment: environment, snapshot: snapshot, networkEnabled: networkChecksEnabled, estimating: true)
    }

    var verificationFindings: [GuardFinding] {
        let order = ["signature", "network", "chromium", "claude-exposure", "exit-history", "exit-geography", "terminal-proxy", "cowork-runtime", "history-storage"]
        return order.compactMap { id in findings.first { $0.id == id } }
    }
    var verificationReminderCount: Int { verificationFindings.filter { $0.state == .attention }.count }
    var verificationUnknownCount: Int { verificationFindings.filter { $0.state == .unknown }.count }

    func start() {
        guard !started, !isDesignPreview else { return }
        started = true
        networkTracker.usageBoundaryChanged()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observe(workspace, name: name) { [weak self] id in
                if GuardClashReader.bundleIDs.contains(id ?? "") {
                    self?.refreshConnectionStatus()
                    self?.refreshNetworkIfNeeded(force: true)
                    return
                }
                guard GuardLauncher.bundleIDs.contains(id ?? "") else { return }
                self?.activityRevision += 1
                self?.networkTracker.usageBoundaryChanged()
                self?.refreshNetworkIfNeeded(force: true)
                self?.webGeneration += 1
                self?.webTask?.cancel()
                self?.snapshot.webEnvironment = .unavailable(.waitingForPage)
                self?.scheduleRefresh()
                self?.refreshConnectionStatus()
            }
        }
        observe(workspace, name: NSWorkspace.didWakeNotification) { [weak self] _ in self?.invalidateNetwork() }
        observe(.default, name: .NSSystemTimeZoneDidChange) { [weak self] _ in self?.scheduleRefresh() }
        observe(.default, name: NSLocale.currentLocaleDidChangeNotification) { [weak self] _ in self?.scheduleRefresh() }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.invalidateNetwork() }
        }
        monitor.start(queue: DispatchQueue(label: "claude-notch-environment-network", qos: .utility))
        pathMonitor = monitor
        refreshConnectionStatus()
        refresh()
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name,
                         handler: @escaping @MainActor @Sendable (String?) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in handler(id) }
        }
        observers.append((center, token))
    }

    func stop() {
        recheckGeneration += 1
        isRechecking = false
        started = false
        debounce?.cancel()
        localTask?.cancel()
        networkTask?.cancel()
        exitRecheckTask?.cancel()
        exitRecheckTask = nil
        fastRecheckTask?.cancel()
        fastRecheckTask = nil
        clashGeneration += 1
        clashTask?.cancel(); clashTask = nil
        clashTimer?.invalidate(); clashTimer = nil
        isCheckingConnection = false
        connectionMonitor.setActive(false)
        notificationTask?.cancel(); notificationTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        periodicTimer?.invalidate()
        periodicTimer = nil
        webTimer?.invalidate()
        webTimer = nil
        webTask?.cancel()
        webTask = nil
        webGeneration += 1
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        isChecking = false
        isCheckingNetwork = false
        pendingRefresh = false
        pendingForce = false
    }

    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        guard !isDesignPreview else { return }
        if visible { refresh() }
        updatePeriodicTimer()
    }

    func updateProfile(_ value: GuardProfile) {
        if value.countryCode != profile.countryCode || value.timeZoneIdentifier != profile.timeZoneIdentifier {
            manualLocationOverride = true
        }
        profile = value
        operationMessage = nil
        if isDesignPreview { recordRiskIfChanged(); return }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.profileKey) }
        refreshWebGuard()
        updatePeriodicTimer()
        recordRiskIfChanged()
        refresh()
    }

    func setNetworkChecksEnabled(_ enabled: Bool) {
        networkChecksEnabled = enabled
        if isDesignPreview { recordRiskIfChanged(); return }
        defaults.set(enabled, forKey: "environmentGuard.networkChecksEnabled")
        if !enabled {
            networkGeneration += 1
            networkTask?.cancel()
            networkTask = nil
            isCheckingNetwork = false
            snapshot.networkInvalidated = true
            networkTracker.invalidateCandidate()
            updateNetworkBehavior()
        } else { refreshNetworkIfNeeded(force: true) }
        updatePeriodicTimer()
        recordRiskIfChanged()
    }

    func selectApplication() {
        guard !isDesignPreview else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              GuardLauncher.bundleIDs.contains(Bundle(url: url)?.bundleIdentifier ?? "") else { return }
        preferredPath = url.path
        defaults.set(url.path, forKey: "environmentGuard.appPath")
        refresh(force: true)
    }

    /// A user-requested refresh remains busy until local, web and route checks finish.
    /// Background monitoring does not replace visible readings with loading placeholders.
    func recheck() async {
        guard !Task.isCancelled, !isRechecking else { return }
        recheckGeneration += 1
        let generation = recheckGeneration
        isRechecking = true
        defer {
            if recheckGeneration == generation { isRechecking = false }
        }
        let clock = ContinuousClock()
        let minimumEnd = clock.now.advanced(by: .milliseconds(350))
        refresh(force: true)
        while isChecking {
            await localTask?.value
            guard !Task.isCancelled, recheckGeneration == generation else { return }
        }
        await networkTask?.value
        await webTask?.value
        guard !Task.isCancelled, recheckGeneration == generation else { return }
        // Keep very fast/cache-only checks from flashing for a single frame.
        let remaining = clock.now.duration(to: minimumEnd)
        if remaining > .zero { try? await Task.sleep(for: remaining) }
    }

    func refresh(force: Bool = false) {
        guard !isDesignPreview else { return }
        guard !isChecking else {
            pendingRefresh = true
            pendingForce = pendingForce || force
            return
        }
        systemEnvironment = .read()
        let running = GuardLauncher.runningApplications
        let current = running.first
        let client: GuardClient? = GuardLauncher.installedURL(preferredPath: preferredPath).map { url in
            GuardClient(path: url.path,
                        version: GuardLauncher.version(at: url),
                        pid: current?.processIdentifier, launchedAt: current?.launchDate,
                        runningInstanceCount: running.count)
        }
        isChecking = true
        localTask = Task { [weak self, inspector] in
            var observation = client
            if let client {
                async let signature = inspector.inspect(path: client.path, version: client.version, force: force)
                let process = await Task.detached(priority: .utility) {
                    client.pid.flatMap { GuardProcessReader.read(pid: $0) }
                }.value
                observation?.signature = await signature
                observation?.process = process
            }
            guard !Task.isCancelled, let self else { return }
            // A process can quit/update while signature verification is in flight.
            if self.currentInstanceKey() != Self.instanceKey(client) {
                self.isChecking = false
                self.refresh(force: force)
                return
            }
            if Self.instanceKey(self.snapshot.client) != Self.instanceKey(observation) {
                self.snapshot.webEnvironment = .unavailable(observation?.pid == nil ? .notRunning : .waitingForPage)
            }
            self.snapshot.client = observation
            let inspectionClient = observation
            let expectedProfile = self.profile
            let inspection = await Task.detached(priority: .utility) {
                let processes = GuardExecutionInspector.processes()
                return (GuardExecutionInspector.proxyCheck(shellProcesses: processes), GuardExecutionInspector.runtimeCheck(client: inspectionClient, processes: processes, expectedProfile: expectedProfile))
            }.value
            guard !Task.isCancelled else { self.isChecking = false; return }
            guard self.currentInstanceKey() == Self.instanceKey(inspectionClient) else {
                self.isChecking = false; self.refresh(force: force); return
            }
            self.isChecking = false
            self.snapshot.proxyCheck = inspection.0
            self.snapshot.runtimeCheck = inspection.1
            self.updateNetworkBehavior()
            self.snapshot.checkedAt = .now
            self.recordRiskIfChanged()
            self.refreshWebGuard()
            self.updatePeriodicTimer()
            self.refreshNetworkIfNeeded(force: force)
            if self.pendingRefresh {
                let forceNext = self.pendingForce
                self.pendingRefresh = false
                self.pendingForce = false
                self.refresh(force: forceNext)
            }
        }
    }

    private static func instanceKey(_ client: GuardClient?) -> String {
        "\(client?.path ?? ""):\(client?.pid ?? 0):\(client?.launchedAt?.timeIntervalSince1970 ?? 0):\(client?.version ?? "")"
    }

    private func currentInstanceKey() -> String {
        let app = GuardLauncher.runningApplications.first
        let url = GuardLauncher.installedURL(preferredPath: preferredPath)
        return "\(url?.path ?? ""):\(app?.processIdentifier ?? 0):\(app?.launchDate?.timeIntervalSince1970 ?? 0):\(url.map { GuardLauncher.version(at: $0) } ?? "")"
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            self?.refresh()
        }
    }

    private func invalidateNetwork() {
        connectionMonitor.invalidateCandidates()
        refreshConnectionStatus()
        networkTracker.invalidateCandidate()
        updateNetworkBehavior()
        exitRecheckTask?.cancel()
        snapshot.networkInvalidated = true
        networkGeneration += 1
        networkTask?.cancel()
        networkTask = nil
        isCheckingNetwork = false
        scheduleRefresh()
    }

    private var shouldProbeNetwork: Bool {
        networkChecksEnabled && started
    }

    private func refreshWebGuard() {
        guard !isDesignPreview else { return }
        webGeneration += 1
        let generation = webGeneration
        webTask?.cancel()
        let client = snapshot.client
        let receipt = receipt
        let enabled = profile.enabled
        webTask = Task { [weak self] in
            let state = await Task.detached(priority: .utility) {
                GuardWebEnvironmentReader.state(client: client, receipt: receipt, enabled: enabled)
            }.value
            guard !Task.isCancelled, let self, generation == self.webGeneration,
                  enabled == self.profile.enabled, self.receipt?.webSession == receipt?.webSession,
                  self.currentInstanceKey() == Self.instanceKey(client) else { return }
            self.snapshot.webEnvironment = state
            self.recordRiskIfChanged()
        }
    }

    private func updatePeriodicTimer() {
        if started && networkChecksEnabled && clashTimer == nil {
            clashTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshConnectionStatus() }
            }
            clashTimer?.tolerance = 3
        } else if !started || !networkChecksEnabled {
            clashTimer?.invalidate(); clashTimer = nil
            clashGeneration += 1; clashTask?.cancel(); clashTask = nil
            isCheckingConnection = false; connectionMonitor.setActive(false)
        }
        let webNeeded = profile.enabled && snapshot.client?.pid != nil
        if webNeeded, webTimer == nil {
            webTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshWebGuard() }
            }
            webTimer?.tolerance = 2
        } else if !webNeeded {
            webTimer?.invalidate()
            webTimer = nil
        }
        let needed = started && networkChecksEnabled
        let interval: TimeInterval = connectionMonitor.active ? 30 : 60
        if needed, periodicTimer == nil || periodicTimer?.timeInterval != interval, started {
            periodicTimer?.invalidate()
            periodicTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                    self?.refreshNetworkIfNeeded(force: true)
                }
            }
            periodicTimer?.tolerance = 5
        } else if !needed {
            periodicTimer?.invalidate()
            periodicTimer = nil
            if networkTask != nil {
                networkGeneration += 1
                networkTask?.cancel()
                networkTask = nil
                isCheckingNetwork = false
            }
        }
    }

    private func refreshNetworkIfNeeded(force: Bool) {
        guard shouldProbeNetwork, !isCheckingNetwork,
              force || !snapshot.networkIsFresh(at: .now) else { return }
        isCheckingNetwork = true
        let generation = networkGeneration
        let exposureRevision = activityRevision
        let startingActivity = activityProvider()
        networkTask = Task { [weak self] in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = GuardRuntimeNetworkLookup.timeout
            configuration.timeoutIntervalForResource = GuardRuntimeNetworkLookup.timeout
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                let observation = try await GuardRuntimeNetworkLookup.observation(session: session)
                guard !Task.isCancelled, let self, self.networkGeneration == generation else { return }
                var activity = GuardDesktopActivityReader.sample(start: startingActivity, end: self.activityProvider(), lifecycleChanged: self.activityRevision != exposureRevision)
                let exit = GuardExit(observation, activity: activity)!
                var verification = GuardGeoVerification.unchecked
                if self.networkTracker.requiresLocationVerification(exit),
                   let candidate = self.networkTracker.candidate(for: exit), candidate.sameRoute(as: exit),
                   exit.observedAt.timeIntervalSince(candidate.observedAt) >= 5 {
                    verification = await self.verifyLocation(exit, session: session)
                }
                guard !Task.isCancelled, self.networkGeneration == generation else { return }
                activity = GuardDesktopActivityReader.sample(start: startingActivity, end: self.activityProvider(), lifecycleChanged: self.activityRevision != exposureRevision)
                self.applyNetworkObservation(observation, verification: verification, activity: activity)
            } catch {
                guard !Task.isCancelled, let self, self.networkGeneration == generation else { return }
                self.networkTracker.invalidateCandidate()
                self.updateNetworkBehavior()
                self.snapshot.networkInvalidated = true
                self.snapshot.networkError = .init("出口查询失败，已重试；保留上次结果。", "Exit lookup failed after retry; the previous observation is retained.")
                self.connectionMonitor.failedExit()
                self.connectionStateDidChange()
                self.recordRiskIfChanged(kind: "check-failed")
            }
            guard let self, self.networkGeneration == generation else { return }
            self.isCheckingNetwork = false
            self.networkTask = nil
            if self.activityRevision != exposureRevision { self.refreshNetworkIfNeeded(force: true) }
        }
    }

    func restoreIPFollowing() {
        manualLocationOverride = false
        applyIPDefaults()
    }

    private func applyIPDefaults() {
        guard !manualLocationOverride, snapshot.networkIsFresh(at: .now), let network = snapshot.network else { return }
        let previous = profile
        let base = Locale(identifier: profile.languageCode).language.languageCode?.identifier ?? "en"
        profile.localeIdentifier = "\(base)_\(network.countryCode)"
        profile.timeZoneIdentifier = network.timeZone ?? ""
        if !isDesignPreview, let data = try? JSONEncoder().encode(profile) { defaults.set(data, forKey: Self.profileKey) }
        refreshWebGuard()
        if !isDesignPreview, previous != profile { refresh() }
    }

    @discardableResult
    func applyNetworkObservation(_ observation: GuardNetworkObservation, verification: GuardGeoVerification = .unchecked,
                                 activity: GuardDesktopActivity? = nil) -> Bool {
        guard let ip = observation.ip, GuardExit.normalizedIP(ip) != nil,
              Locale.Region.isoRegions.contains(where: { $0.identifier == observation.countryCode }),
              (0..<180).contains(Date.now.timeIntervalSince(observation.fetchedAt)),
              snapshot.network.map({ observation.fetchedAt > $0.fetchedAt }) ?? true else { return false }
        snapshot.desktopActivity = activity ?? (isDesignPreview ? snapshot.desktopActivity : activityProvider())
        snapshot.network = observation
        snapshot.networkInvalidated = false
        snapshot.networkError = nil
        processNetworkObservation(verification: verification)
        return true
    }

    private func processNetworkObservation(verification: GuardGeoVerification) {
        guard let network = snapshot.network, let exit = GuardExit(network, activity: snapshot.desktopActivity) else { return }
        if !isDesignPreview {
            connectionMonitor.setActive(networkChecksEnabled && snapshot.desktopActivity == .active)
            connectionMonitor.observe(exit)
            connectionStateDidChange()
        }
        let first = !networkTracker.hasLaunchSample
        let family = GuardNetworkTracker.family(exit)
        let previousExit = lastJournaledByFamily[family] ?? networkTracker.previousObserved(for: exit)
        let changed = lastJournaledByFamily[family].map { !exit.sameRoute(as: $0) } ?? true
        networkTracker.observe(exit, verification: verification)
        updateNetworkBehavior()
        do {
            if !isDesignPreview && !historyReadFailed { try historyStore.save(networkTracker.history) }
            historyError = historyReadFailed
        } catch { historyError = true }
        snapshot.historyUnavailable = historyError
        if !snapshot.networkBehavior.locationUnverified,
           networkTracker.candidate(for: exit).map({ networkTracker.previous(for: $0)?.country == $0.country }) ?? true { applyIPDefaults() }
        if first || changed {
            let kind = needsExposureRuleLog ? "rule-updated" : first ? "tool-start" : "exit-change"
            if appendExitLog(exit, kind: kind, previous: previousExit) {
                lastJournaledByFamily[family] = exit
                needsExposureRuleLog = false
            }
        } else {
            recordRiskIfChanged(kind: lastLoggedRisk?.desktopActivity != snapshot.desktopActivity ? "usage-change" : "risk-change")
        }
        exitRecheckTask?.cancel()
        if networkTracker.candidate(for: exit).map({ exit.observedAt.timeIntervalSince($0.observedAt) < 5 }) == true
            || connectionMonitor.candidates[family] != nil {
            exitRecheckTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.refreshNetworkIfNeeded(force: true)
            }
        }
    }

    private func updateNetworkBehavior() {
        let previous = snapshot.networkBehavior
        let next = networkTracker.assessment(at: .now)
        snapshot.exitChange = networkTracker.alert
        snapshot.networkBehavior = next
        if hasNetworkWarning, next.shouldExpand, next.identifier != previous.identifier,
           next.points >= previous.points || previous.kind == nil {
            networkNoticeGeneration += 1
        }
    }

    private func verifyLocation(_ exit: GuardExit, session: URLSession) async -> GuardGeoVerification {
        guard let previous = networkTracker.previous(for: exit) else { return .unavailable }
        let key = previous.ip + previous.country + "-" + exit.ip + exit.country
        if let cached = locationVerificationCache[key], Date.now.timeIntervalSince(cached.0) < 60 { return cached.1 }
        var state = GuardGeoVerification.verified
        for item in [previous, exit] {
            do {
                var components = URLComponents(url: URL(string: "https://ipwho.is/")!.appendingPathComponent(item.ip), resolvingAgainstBaseURL: false)!
                components.queryItems = [.init(name: "fields", value: "success,ip,country_code")]
                let (data, response) = try await session.data(from: components.url!)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 8192 else { throw URLError(.badServerResponse) }
                state = GuardLocationVerifier.evaluate(data, expected: item)
                if state != .verified { break }
            } catch { state = .unavailable; break }
        }
        locationVerificationCache[key] = (.now, state)
        if locationVerificationCache.count > 32 { locationVerificationCache = [key: (.now, state)] }
        return state
    }

    func ignoreNetworkRisk() {
        notificationTask?.cancel(); notificationTask = nil
        connectionMonitor.acknowledge()
        networkTracker.ignoreWarning(at: .now)
        persistNetworkHistory()
        if let network = snapshot.network, let exit = GuardExit(network, activity: snapshot.desktopActivity) { appendExitLog(exit, kind: "user-ignored") }
    }

    private var currentLoggedRisk: GuardLoggedRisk {
        .init(systemTotal: currentRisk.total, configuredTotal: configuredRisk.total, networkPoints: configuredRisk.network,
            minimumTotal: snapshot.networkBehavior.minimumTotal, behavior: snapshot.networkBehavior.kind,
            locationUnverified: snapshot.networkBehavior.locationUnverified, desktopActivity: snapshot.desktopActivity)
    }

    @discardableResult
    private func appendExitLog(_ exit: GuardExit, kind: String, previous: GuardExit? = nil) -> Bool {
        let risk = currentLoggedRisk
        if isDesignPreview {
            previewLogEntries.append(.init(recordID: UUID(), kind: kind, exit: exit, recordedAt: .now, previous: previous, risk: risk, previousRisk: lastLoggedRisk))
        } else {
            do { try historyStore.appendObservation(exit, kind: kind, previous: previous, risk: risk, previousRisk: lastLoggedRisk, recordedAt: .now) }
            catch { historyError = true; snapshot.historyUnavailable = true; return false }
        }
        lastLoggedRisk = risk
        exitLogRevision += 1
        return true
    }

    private func recordRiskIfChanged(kind: String = "risk-change") {
        guard networkTracker.hasLaunchSample, let network = snapshot.network,
              let exit = GuardExit(network, activity: snapshot.desktopActivity), currentLoggedRisk != lastLoggedRisk else { return }
        appendExitLog(exit, kind: kind)
    }

    func loadExitHistory(before: UInt64? = nil) async throws -> GuardNetworkLogPage {
        if isDesignPreview {
            let end = min(before ?? UInt64(previewLogEntries.count), UInt64(previewLogEntries.count))
            let start = end > 50 ? end - 50 : 0
            return .init(entries: Array(previewLogEntries[Int(start)..<Int(end)].reversed()), nextOffset: start > 0 ? start : nil)
        }
        let store = historyStore
        return try await Task.detached(priority: .utility) { try store.readJournal(before: before) }.value
    }

    private func persistNetworkHistory() {
        do {
            if !isDesignPreview && !historyReadFailed { try historyStore.save(networkTracker.history) }
        } catch { historyError = true; snapshot.historyUnavailable = true }
    }

    func closeClaudeForNetworkRisk(language: AppLanguage = .chinese) async {
        guard !isClosingClaude, !isLaunching else { return }
        #if DEBUG
        if isDesignPreview {
            isClosingClaude = true
            let instance = snapshot.client?.launchedAt
            try? await Task.sleep(for: .milliseconds(300))
            if snapshot.client?.launchedAt == instance {
                if let client = snapshot.client {
                    snapshot.client = .init(path: client.path, version: client.version, pid: nil,
                        launchedAt: nil, signature: client.signature, runningInstanceCount: 0)
                }
                snapshot.webEnvironment = .unavailable(.notRunning)
                snapshot.desktopActivity = .inactive
                connectionMonitor.setActive(false)
                networkTracker.usageBoundaryChanged()
                recordRiskIfChanged(kind: "usage-change")
            }
            isClosingClaude = false
            return
        }
        #endif
        guard !isDesignPreview else { return }
        isClosingClaude = true
        defer { isClosingClaude = false }
        do {
            try await GuardRestartCoordinator.run(requestExit: {
                GuardLauncher.runningApplications.map { $0.terminate() }.allSatisfy { $0 }
            }, isRunning: { !GuardLauncher.runningApplications.isEmpty }, launch: {})
            refresh(force: true)
        } catch {
            let alert = NSAlert()
            alert.messageText = language.text("Claude 未能退出", "Could not quit Claude")
            alert.informativeText = (error as? GuardRestartError) == .timedOut
                ? language.text("等待超过 15 秒，Claude 尚未退出。请完成客户端中的退出确认后重试。", "Claude has not quit after 15 seconds. Complete any quit confirmation in the client and retry.")
                : error.localizedDescription
            alert.addButton(withTitle: language.text("好", "OK"))
            alert.runModal()
        }
    }

    func confirmNewExit() {
        connectionMonitor.confirmExit()
        guard snapshot.networkIsFresh(at: .now), let network = snapshot.network, let exit = GuardExit(network, activity: snapshot.desktopActivity),
              networkTracker.confirm(exit) else { refreshNetworkIfNeeded(force: true); return }
        snapshot.exitChange = nil
        networkTracker.ignoreWarning(at: .now)
        do {
            if !isDesignPreview {
                if !historyReadFailed { try historyStore.save(networkTracker.history) }
            }
            historyError = historyReadFailed
        } catch { historyError = true }
        snapshot.historyUnavailable = historyError
        appendExitLog(exit, kind: "user-confirmed")
    }

    func showExitHistory() {
        guard !isDesignPreview else { return }
        let file = historyStore.url.deletingLastPathComponent().appendingPathComponent("network-exits.jsonl")
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }

    private var extendedFindings: [GuardFinding] {
        let proxy = snapshot.proxyCheck, runtime = snapshot.runtimeCheck
        let old = networkTracker.previousLaunch?.label(.chinese) ?? "首次启动"
        let new = snapshot.network.flatMap { GuardExit($0, activity: snapshot.desktopActivity) }?.label(.chinese) ?? "待检测"
        var result: [GuardFinding] = [
            .init(id: "exit-history", title: .init("出口 IP 记录", "Exit IP history"),
                  value: .init(historyError ? "出口记录未核验" : exitAlert != nil ? "IP 出口改变" : networkTracker.hasLaunchSample ? "出口基准已记录" : "等待出口检测", historyError ? "Exit history unverified" : exitAlert != nil ? "Exit IP changed" : networkTracker.hasLaunchSample ? "Exit baseline recorded" : "Waiting for exit check"),
                  detail: .init("上次工具启动：\(old)\n本次出口：\(new)\n仅本机记录；确认或忽略不会清除跨区历史与近期风险。",
                                "Previous tool launch: \(networkTracker.previousLaunch?.label(.english) ?? "First launch")\nCurrent: \(snapshot.network.flatMap { GuardExit($0, activity: snapshot.desktopActivity) }?.label(.english) ?? "Not checked")\nHistory stays local. Confirmation or dismissal does not erase geographic history or risk."),
                  state: historyError ? .unknown : exitAlert != nil ? .attention : networkTracker.hasLaunchSample ? .information : .unknown,
                  actionID: exitAlert != nil ? "exit-change" : nil),
            .init(id: "terminal-proxy", title: .init("终端旧代理排查", "Terminal proxy check"),
                  value: proxy.summary,
                  detail: .init((proxy.definitions + proxy.activeVariables).joined(separator: "\n") + "\n只读检查本工具继承的变量、常见 shell 启动文件与 Code 用户设置；不执行文件、不显示代理密码，定义存在不等于已生效。",
                                (proxy.definitions + proxy.activeVariables).joined(separator: "\n") + "\nRead-only inherited variables, shell startup files and Code user settings. Definitions alone do not prove active routing; credentials are omitted."),
                  state: proxy.state,
                  actionID: proxy.points > 0 ? "terminal-proxy" : nil),
            .init(id: "cowork-runtime", title: .init("Cowork 执行链路", "Cowork execution chain"), value: runtime.location,
                  detail: .init((runtime.execution + runtime.environmentSamples + runtime.browsers).joined(separator: "\n") + "\n仅按可信进程路径与父子关系核验；没有本机进程不表示已确认云端，网页读数不代替后台或浏览器的实际出口。",
                                (runtime.execution + runtime.environmentSamples + runtime.browsers).joined(separator: "\n") + "\nTrusted process ancestry only. No local process does not prove cloud execution. Page readings do not verify background or browser egress."),
                  state: runtime.backgroundMismatch ? .attention : runtime.desktopRunning ? .unknown : .information,
                  actionID: runtime.backgroundMismatch ? "runtime-environment" : nil)
        ]
        let behavior = snapshot.networkBehavior
        let activity = snapshot.desktopActivity
        let activityValue = activity == .inactive ? GuardText("未运行期间豁免", "Inactive-period exemption")
            : activity == .active ? GuardText("检测到运行／执行进程", "Execution observed") : GuardText("运行状态待核验", "Activity unverified")
        result.append(.init(id: "claude-exposure", title: .init("运行期出口计分", "Exposure-scoped exit scoring"), value: activityValue,
            detail: .init("只有桌面端或可信 Claude／Cowork 执行进程运行时观测到的出口，才进入跨区累计。未运行时的 IP 变化仍保留日志，不新增异常下限；运行前后比较实际使用出口，中间离线跳转不计成额外往返。"
                + (networkTracker.hasLegacyExposureHistory ? "\n旧记录没有保存运行状态，原日志和原评分保留，未纳入新版已确认累计。" : ""),
                          "Only exits observed while Desktop or trusted execution runs contribute to region counts. Inactive changes stay in the log without new anomaly floors. Resumed use compares actual exposed endpoints; offline intermediate hops are excluded."
                + (networkTracker.hasLegacyExposureHistory ? "\nLegacy records lack activity evidence; original logs and scores remain but do not contribute to new confirmed counts." : "")),
            state: activity == .unknown || networkTracker.hasLegacyExposureHistory ? .unknown : .information))
        if behavior.kind != nil {
            result.append(.init(id: "exit-geography", title: .init("出口地理变化", "Exit geography"),
                value: .init(behavior.title(.chinese), behavior.title(.english)),
                detail: .init("24 小时运行期跨区 \(behavior.crossRegionCount) 次，涉及 \(behavior.regionCount) 个国家／地区；1 小时已核验异常 \(behavior.anomalousCount) 次。\n同国 IP 和城市变化不计分。远距跨区先复核并核对第二定位来源；一次风险至少 50，连续或往返至少 80。稳定有效观察 2 小时后解除 80 下限，24 小时后解除 50 下限；忽略不清除评分。",
                              "24h exposure-period region changes: \(behavior.crossRegionCount); regions: \(behavior.regionCount); verified anomalies in 1h: \(behavior.anomalousCount).\nSame-country IP/city changes add no points. Remote switches need repeated samples and two location sources. One anomaly sets a minimum of 50, repeated/return switches 80. Verified stability reduces these floors after 2h/24h. Ignoring preserves risk."),
                state: behavior.locationUnverified ? .unknown : .attention, actionID: "exit-geography"))
        }
        if historyError {
            result.append(.init(id: "history-storage", title: .init("出口记录存储", "Exit history storage"), value: .init("记录未完成", "History unavailable"),
                                detail: .init("本机出口记录无法读取或写入，不能确认下次启动比较已准备好。", "Local history could not be read or saved; next-launch comparison is not verified."), state: .unknown))
        }
        return result
    }

    private func prepareAutomaticLocation(allowUnverified: Bool = false) async throws {
        guard profile.enabled, followingIP, networkChecksEnabled else { return }
        if allowUnverified && profile.isValid { return }
        if !snapshot.networkIsFresh(at: .now) {
            refreshNetworkIfNeeded(force: true)
            await networkTask?.value
        }
        guard snapshot.networkIsFresh(at: .now), profile.isValid else { throw GuardLaunchError.locationUnavailable }
    }

    @discardableResult
    func launchClaude() async -> Bool {
        guard !isDesignPreview else { return false }
        guard !isLaunching, !isClosingClaude else { return false }
        isLaunching = true
        defer { isLaunching = false }
        operationMessage = nil
        operationFailed = false
        do {
            guard let url = launchActions.installedURL(preferredPath) else { throw GuardLaunchError.notInstalled }
            guard let approval = try await authorizeNetworkLaunch() else { return false }
            try await prepareAutomaticLocation(allowUnverified: approval.exit == nil)
            let launchProfile = profile
            if launchProfile.enabled, !launchActions.running().isEmpty { throw GuardLaunchError.alreadyRunning }
            let webSession = launchProfile.enabled ? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() : nil
            if webSession != nil { try GuardWebEnvironmentReader.prepareDirectory() }
            let configuration = try GuardLauncher.configuration(profile: launchProfile, webSession: webSession)
            guard let finalApproval = try await authorizeNetworkLaunch(approved: approval.fingerprint) else { return false }
            try Task.checkCancellation()
            guard profile == launchProfile else { throw GuardRestartError.profileChanged }
            if launchProfile.enabled, !launchActions.running().isEmpty { throw GuardLaunchError.alreadyRunning }
            let app = try await launchActions.open(url, configuration)
            recordConnectionLaunch(finalApproval)
            if launchProfile.enabled {
                let record = LaunchReceipt(pid: app.processIdentifier, launchedAt: app.launchDate ?? .now,
                                           appPath: url.path, profile: launchProfile, webSession: webSession)
                receipt = record
                if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: Self.receiptKey) }
                operationMessage = .init("配置已提交，正在核对启动参数；内部运行环境仍需验证。", "Profile submitted; checking launch settings. Internal runtime values remain unverified.")
            } else {
                operationMessage = .init("已正常启动 Claude。专属启动配置未启用。", "Claude launched normally; the launch profile is off.")
            }
            operationFailed = false
            refresh(force: true)
            return true
        } catch {
            operationFailed = true
            operationMessage = .init(error.localizedDescription, error.localizedDescription)
            refresh()
            return false
        }
    }

    func restartWithoutProfile() async -> Bool {
        guard !profile.enabled else { return false }
        return await restartClaude()
    }

    /// The same normal-quit flow applies saved edits without creating a second instance.
    func restartWithProfile() async -> Bool {
        guard profile.enabled, profile.isValid else { return false }
        return await restartClaude()
    }

    private func restartClaude() async -> Bool {
        guard !isDesignPreview, !isLaunching, !isClosingClaude else { return false }
        isLaunching = true
        defer { isLaunching = false }
        operationMessage = nil
        operationFailed = false
        do {
            guard let url = launchActions.installedURL(preferredPath) else { throw GuardLaunchError.notInstalled }
            guard let approval = try await authorizeNetworkLaunch() else { return false }
            try await prepareAutomaticLocation(allowUnverified: approval.exit == nil)
            let launchProfile = profile
            let webSession = launchProfile.enabled ? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() : nil
            if webSession != nil { try GuardWebEnvironmentReader.prepareDirectory() }
            let configuration = try GuardLauncher.configuration(profile: launchProfile.enabled ? launchProfile : nil, webSession: webSession)
            guard let beforeQuit = try await authorizeNetworkLaunch(approved: approval.fingerprint) else { return false }
            var launchedApp: NSRunningApplication?
            try await GuardRestartCoordinator.run(requestExit: {
                return self.launchActions.quit()
            }, isRunning: { !self.launchActions.running().isEmpty }, launch: {
                guard self.profile == launchProfile else { throw GuardRestartError.profileChanged }
                guard self.launchActions.running().isEmpty else { throw GuardLaunchError.alreadyRunning }
                guard let finalApproval = try await self.authorizeNetworkLaunch(approved: beforeQuit.fingerprint) else { return }
                try Task.checkCancellation()
                guard self.profile == launchProfile else { throw GuardRestartError.profileChanged }
                guard self.launchActions.running().isEmpty else { throw GuardLaunchError.alreadyRunning }
                launchedApp = try await self.launchActions.open(url, configuration)
                self.recordConnectionLaunch(finalApproval)
            })
            guard launchedApp != nil else { return false }
            if launchProfile.enabled, let app = launchedApp {
                let record = LaunchReceipt(pid: app.processIdentifier, launchedAt: app.launchDate ?? .now,
                                           appPath: url.path, profile: launchProfile, webSession: webSession)
                receipt = record
                if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: Self.receiptKey) }
            } else {
                receipt = nil
                defaults.removeObject(forKey: Self.receiptKey)
            }
            operationFailed = false
            refresh(force: true)
            return true
        } catch {
            operationFailed = true
            operationMessage = .init(error.localizedDescription, error.localizedDescription)
            refresh()
            return false
        }
    }

    /// Preserve the ordinary deep-link flow unless a configured cold launch is required.
    func prepareForHandoff() async -> Bool {
        guard !isDesignPreview, !isLaunching, !isClosingClaude else { return false }
        if launchActions.running().isEmpty { return await launchClaude() }
        isLaunching = true; operationFailed = false
        defer { isLaunching = false }
        do { return try await authorizeNetworkLaunch() != nil }
        catch { operationFailed = true; operationMessage = .init(error.localizedDescription, error.localizedDescription); return false }
    }

    func recheckConnection() {
        guard !isDesignPreview else { return }
        refreshConnectionStatus()
        refreshNetworkIfNeeded(force: true)
    }

    func applyClashObservation(_ state: GuardClashState, activity: GuardDesktopActivity) {
        connectionMonitor.setActive(networkChecksEnabled && activity == .active)
        connectionMonitor.observeClash(state, at: .now)
        connectionStateDidChange()
    }

    private func refreshConnectionStatus() {
        guard started, networkChecksEnabled, !isDesignPreview else { return }
        let wasActive = connectionMonitor.active
        connectionMonitor.setActive(activityProvider() == .active)
        updatePeriodicTimer()
        if connectionMonitor.active != wasActive { refreshNetworkIfNeeded(force: true) }
        guard !isCheckingConnection else { return }
        isCheckingConnection = true
        let generation = clashGeneration
        clashTask = Task { [weak self, clashProvider] in
            let mode = await clashProvider()
            guard let self, !Task.isCancelled, generation == self.clashGeneration else { return }
            self.applyClashObservation(mode, activity: self.activityProvider())
            self.isCheckingConnection = false
            self.clashTask = nil
            self.connectionStateDidChange()
        }
    }

    private func connectionStateDidChange() {
        let baselines = connectionMonitor.baselines
        if networkTracker.history.connectionBaselines != baselines {
            networkTracker.setConnectionBaselines(baselines)
            persistNetworkHistory()
        }
        guard !isDesignPreview, !isLaunching else { return }
        if connectionMonitor.visibleIssues.isEmpty { notificationTask?.cancel(); notificationTask = nil }
        let fresh = connectionMonitor.takeNewNotice()
        guard !fresh.isEmpty else { return }
        networkNoticeGeneration += 1
        let visible = connectionMonitor.visibleIssues
        notificationTask?.cancel()
        notificationTask = Task { [notificationSender] in await notificationSender(visible) }
    }

    private func recordConnectionLaunch(_ sample: GuardLaunchNetworkSample) {
        connectionMonitor.setActive(true)
        connectionMonitor.acceptLaunch(sample.exit)
        connectionMonitor.observeClash(sample.clash, at: .now)
        if let exit = sample.exit { connectionMonitor.observe(exit) }
        else { connectionMonitor.failedExit() }
        // The user just accepted these conditions; keep them visible without immediately
        // sending the same warning again after the launch notification arrives.
        _ = connectionMonitor.takeNewNotice()
        networkTracker.setConnectionBaselines(connectionMonitor.baselines)
        persistNetworkHistory()
    }

    private func authorizeNetworkLaunch(approved: String? = nil) async throws -> GuardLaunchNetworkSample? {
        let baseline = connectionMonitor.baselines
        let result = try await GuardLaunchNetworkGate.authorize(baselines: baseline, approved: approved, sample: {
            if self.networkChecksEnabled { return await self.launchNetworkSampler() }
            return .init(exit: nil, clash: await self.clashProvider())
        }, confirm: { sample, issues in
            if let confirm = self.launchConfirmation { return await confirm(sample, issues) }
            let language = AppLanguage.saved
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = language.text("启动 Claude 前，请确认网络", "Check the network before launching Claude")
            alert.informativeText = issues.map { issue in
                issue.message(language) + (issue.change.map { "\n\($0.previous.ip) → \($0.current.ip)" } ?? "")
            }.joined(separator: "\n") + "\n" + language.text("本次检测：", "Checked: ") + Date.now.formatted(date: .omitted, time: .standard)
            alert.addButton(withTitle: language.text("取消", "Cancel"))
            alert.addButton(withTitle: language.text("仍然启动", "Launch anyway"))
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[1].keyEquivalent = ""
            return alert.runModal() == .alertSecondButtonReturn
        })
        if result == nil {
            operationFailed = false
            operationMessage = .init("已取消启动，未继续执行。", "Launch cancelled; no further action was taken.")
        }
        return result
    }
}

// MARK: - Risk banner and first-run welcome

extension EnvironmentGuardService {
    private var evaluatedProtectionState: GuardProtectionState {
        .evaluate(profile: profile, client: snapshot.client, receipt: receipt)
    }

    /// First run only: no protected launch was ever recorded and the card was never answered.
    var showsWelcome: Bool { !welcomeResolved && receipt == nil }

    var hasRiskBanner: Bool { !riskBanner.isEmpty }

    private var protectionInstanceKey: String? {
        guard let client = snapshot.client, let pid = client.pid else { return nil }
        return "\(pid)-\(Int(client.launchedAt?.timeIntervalSince1970 ?? 0))"
    }

    /// Live banner items in display order: protection, Clash, unknown exit, IP change, geography.
    var riskItems: [GuardRiskItem] {
        var items: [GuardRiskItem] = []
        let state = evaluatedProtectionState
        if state.isUnprotectedRun, !showsWelcome, let key = protectionInstanceKey, key != ignoredProtectionInstance {
            items.append(.init(id: "protection-" + key, kind: .protection(state)))
        }
        let issues = connectionMonitor.visibleIssues
        for issue in issues where issue.kind == .clash {
            items.append(.init(id: issue.id, kind: .clash(issue.clash ?? .unknown)))
        }
        for issue in issues where issue.kind == .exitUnknown {
            items.append(.init(id: issue.id, kind: .exitUnknown))
        }
        for issue in issues where issue.kind == .ipChanged {
            if let change = issue.change { items.append(.init(id: issue.id, kind: .ipChanged(change))) }
        }
        if hasGeographicWarning {
            items.append(.init(id: "geo-" + snapshot.networkBehavior.identifier, kind: .geography))
        }
        return items
    }

    /// An item that disappeared counts as fixed only while its source is still being watched.
    func reconcileRiskBanner(now: Date = .now) {
        let state = evaluatedProtectionState
        if protectionState != state { protectionState = state }
        let monitoring = connectionMonitor.active && networkChecksEnabled
        riskBanner.reconcile(riskItems, resolvable: { item in
            switch item.kind {
            case .protection: state == .protected
            case .geography: true
            default: monitoring
            }
        }, now: now)
        // Expand the notch once for each instance opened outside the notch while the profile is on.
        if case .notFromNotch = state, !showsWelcome, let key = protectionInstanceKey,
           key != ignoredProtectionInstance, key != announcedProtectionInstance {
            announcedProtectionInstance = key
            networkNoticeGeneration += 1
        }
        scheduleBannerDeadline()
    }

    private func scheduleBannerDeadline() {
        bannerTimer?.cancel()
        guard let deadline = riskBanner.nextDeadline else { bannerTimer = nil; return }
        let delay = max(0.05, deadline.timeIntervalSinceNow)
        bannerTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconcileRiskBanner()
        }
    }

    private func observeRiskItems() {
        withObservationTracking {
            _ = riskItems
            _ = connectionMonitor.active
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.reconcileRiskBanner()
                self?.observeRiskItems()
            }
        }
    }

    /// The row's ×: hides this item only. Risk history and scores stay unchanged.
    func ignoreRiskItem(_ id: String) {
        guard let item = riskBanner.rows.first(where: { $0.id == id })?.item ?? riskItems.first(where: { $0.id == id }) else { return }
        riskBanner.ignore(id)
        switch item.kind {
        case .protection:
            ignoredProtectionInstance = protectionInstanceKey
        case .clash, .exitUnknown:
            connectionMonitor.acknowledge(id)
        case .ipChanged:
            connectionMonitor.acknowledge(id)
            logIgnoredExit()
        case .geography:
            networkTracker.ignoreWarning(at: .now)
            persistNetworkHistory()
            logIgnoredExit()
        }
        if connectionMonitor.visibleIssues.isEmpty { notificationTask?.cancel(); notificationTask = nil }
        reconcileRiskBanner()
    }

    private func logIgnoredExit() {
        if let network = snapshot.network, let exit = GuardExit(network, activity: snapshot.desktopActivity) {
            appendExitLog(exit, kind: "user-ignored")
        }
    }

    /// Clash rows: open Clash Verge, then re-read the local core every 3 s for up to a minute.
    /// The mode itself is never changed here.
    func openClashForRisk(_ id: String, language: AppLanguage) {
        riskBanner.markChecking(id, until: .now.addingTimeInterval(60))
        scheduleBannerDeadline()
        fastRecheckTask?.cancel()
        if isDesignPreview {
            // Demo data only: act as if the user switched Clash to global a moment later.
            fastRecheckTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled else { return }
                self.connectionMonitor.observeClash(.global, at: .now)
            }
            return
        }
        if !GuardClashReader.open() { GuardVPNToolOpener.open(language: language) }
        fastRecheckTask = Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(3))
                guard let self, !Task.isCancelled,
                      self.riskItems.contains(where: { if case .clash = $0.kind { true } else { false } }) else { return }
                self.refreshConnectionStatus()
            }
        }
    }

    /// "Recheck" rows stay in the checking state until this round of local checks finishes.
    func recheckRisk(_ id: String) {
        riskBanner.markChecking(id, until: .now.addingTimeInterval(15))
        scheduleBannerDeadline()
        if isDesignPreview {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                self.connectionMonitor.observeClash(.global, at: .now)
                if let network = self.snapshot.network, let exit = GuardExit(network, activity: .active) {
                    self.connectionMonitor.observe(exit)
                }
            }
            return
        }
        recheckConnection()
        let clash = clashTask, network = networkTask
        Task { [weak self] in
            await clash?.value
            await network?.value
            guard let self else { return }
            self.riskBanner.settle(id, isCurrent: self.riskItems.contains { $0.id == id })
            self.reconcileRiskBanner()
        }
    }

    /// "It was me": the current exit becomes the new baseline.
    func confirmExitForRisk() {
        confirmNewExit()
        reconcileRiskBanner()
    }

    /// Restarts Claude with the profile, turning it on first if needed. The caller asks the user first.
    func relaunchWithProtection(itemID: String?) async -> Bool {
        if let itemID {
            riskBanner.markChecking(itemID, until: .now.addingTimeInterval(90))
            scheduleBannerDeadline()
        }
        #if DEBUG
        if isDesignPreview {
            try? await Task.sleep(for: .seconds(1.5))
            if let client = snapshot.client {
                var process = GuardProcessConfiguration()
                process.language = profile.languageCode
                process.appleLanguages = "(\(profile.languageCode))"
                process.locale = profile.localeIdentifier
                process.timeZone = profile.timeZoneIdentifier
                var next = client
                next.process = process
                snapshot.client = next
            }
            return true
        }
        #endif
        guard !isDesignPreview else { return false }
        if !profile.enabled {
            var value = profile
            value.enabled = true
            updateProfile(value)
        }
        let launched = await restartWithProfile()
        if !launched, let itemID {
            riskBanner.settle(itemID, isCurrent: riskItems.contains { $0.id == itemID })
            reconcileRiskBanner()
        }
        return launched
    }

    func dismissWelcome() { resolveWelcome("dismissed") }

    private func resolveWelcome(_ value: String) {
        welcomeResolved = true
        if !isDesignPreview { defaults.set(value, forKey: Self.welcomeKey) }
    }

    /// Welcome card: turn the profile on, then launch Claude with it, or restart a running Claude.
    /// The card stays when the user cancels the network check or the launch fails.
    func enableProtectionAndLaunch() async -> Bool {
        if isDesignPreview { resolveWelcome("done"); return true }
        if !profile.enabled {
            var value = profile
            value.enabled = true
            updateProfile(value)
        }
        let launched = launchActions.running().isEmpty ? await launchClaude() : await restartWithProfile()
        if launched { resolveWelcome("done") }
        return launched
    }
}
