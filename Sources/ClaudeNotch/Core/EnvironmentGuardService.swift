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
    case notInstalled, invalidProfile, alreadyRunning

    var errorDescription: String? {
        switch self {
        case .notInstalled: "未找到 Claude Desktop / Claude Desktop not found"
        case .invalidProfile: "请先选择有效的地区和时区 / Choose a valid region and timezone"
        case .alreadyRunning: "请先正常退出 Claude，再按配置启动 / Quit Claude normally before a configured launch"
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
    private(set) var windowVisible = false
    private(set) var networkChecksEnabled: Bool
    private(set) var operationMessage: GuardText?
    private(set) var operationFailed = false
    private(set) var isDesignPreview = false

    #if DEBUG
    func loadDesignPreview() { loadDesignPreview(running: false) }

    func loadDesignPreview(running: Bool, rechecking: Bool = false) {
        stop()
        isDesignPreview = true
        isRechecking = rechecking
        systemEnvironment = .init(languageCode: "zh-CN", localeIdentifier: "zh_CN", timeZoneIdentifier: "Asia/Shanghai")
        profile = GuardProfile(enabled: true, languageCode: "en-US", localeIdentifier: "en_US", timeZoneIdentifier: "America/Los_Angeles")
        snapshot = GuardSnapshot(client: .init(path: "/Applications/Claude.app", version: "1.49585.0", pid: running ? Int32.max : nil,
                                               launchedAt: running ? .now : nil, signature: .local, runningInstanceCount: running ? 1 : 0), checkedAt: .now,
                                 network: .init(countryCode: "TR", fetchedAt: .now, city: "Istanbul"), networkInvalidated: false)
        if running {
            snapshot.webEnvironment = .observed(.init(protocol: 1, session: "preview", pid: Int32.max,
                capturedAt: Date.now.timeIntervalSince1970 * 1000, candidateCount: 1, failedCount: 0,
                frames: [.init(context: "claude.ai", language: "en-US", languages: ["en-US"], locale: "en-US", timeZone: "America/Los_Angeles")]))
        }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profile = defaults.data(forKey: Self.profileKey).flatMap { try? JSONDecoder().decode(GuardProfile.self, from: $0) } ?? .init()
        receipt = defaults.data(forKey: Self.receiptKey).flatMap { try? JSONDecoder().decode(LaunchReceipt.self, from: $0) }
        networkChecksEnabled = defaults.object(forKey: "environmentGuard.networkChecksEnabled") as? Bool ?? true
        preferredPath = defaults.string(forKey: "environmentGuard.appPath")
    }

    var findings: [GuardFinding] {
        GuardEvaluator.findings(profile: profile, snapshot: snapshot, networkEnabled: networkChecksEnabled)
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
        return GuardRiskEvaluator.assess(environment: environment, snapshot: snapshot, networkEnabled: networkChecksEnabled)
    }

    var verificationFindings: [GuardFinding] {
        let order = ["signature", "network", "chromium"]
        return order.compactMap { id in findings.first { $0.id == id } }
    }
    var verificationReminderCount: Int { verificationFindings.filter { $0.state == .attention }.count }
    var verificationUnknownCount: Int { verificationFindings.filter { $0.state == .unknown }.count }

    func start() {
        guard !started, !isDesignPreview else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observe(workspace, name: name) { [weak self] id in
                guard GuardLauncher.bundleIDs.contains(id ?? "") else { return }
                self?.webGeneration += 1
                self?.webTask?.cancel()
                self?.snapshot.webEnvironment = .unavailable(.waitingForPage)
                self?.scheduleRefresh()
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
        profile = value
        operationMessage = nil
        guard !isDesignPreview else { return }
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: Self.profileKey) }
        refreshWebGuard()
        updatePeriodicTimer()
    }

    func setNetworkChecksEnabled(_ enabled: Bool) {
        networkChecksEnabled = enabled
        guard !isDesignPreview else { return }
        defaults.set(enabled, forKey: "environmentGuard.networkChecksEnabled")
        if !enabled {
            networkGeneration += 1
            networkTask?.cancel()
            networkTask = nil
            isCheckingNetwork = false
            snapshot.networkInvalidated = true
        } else { refreshNetworkIfNeeded(force: true) }
        updatePeriodicTimer()
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
            self.isChecking = false
            // A process can quit/update while signature verification is in flight.
            if self.currentInstanceKey() != Self.instanceKey(client) {
                self.refresh(force: force)
                return
            }
            if Self.instanceKey(self.snapshot.client) != Self.instanceKey(observation) {
                self.snapshot.webEnvironment = .unavailable(observation?.pid == nil ? .notRunning : .waitingForPage)
            }
            self.snapshot.client = observation
            self.snapshot.checkedAt = .now
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
        snapshot.networkInvalidated = true
        networkGeneration += 1
        networkTask?.cancel()
        networkTask = nil
        isCheckingNetwork = false
        scheduleRefresh()
    }

    private var shouldProbeNetwork: Bool {
        networkChecksEnabled && (windowVisible || !GuardLauncher.runningApplications.isEmpty)
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
        }
    }

    private func updatePeriodicTimer() {
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
        let needed = windowVisible || !GuardLauncher.runningApplications.isEmpty
        if needed, periodicTimer == nil, started {
            periodicTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            periodicTimer?.tolerance = 30
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
        networkTask = Task { [weak self] in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                let (data, response) = try await session.data(from: URL(string: "https://api.country.is/?fields=city,subdivision")!)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 65_536 else {
                    throw URLError(.badServerResponse)
                }
                let result = try JSONDecoder().decode(GuardCountryResponse.self, from: data)
                guard result.country.count == 2,
                      Locale.Region.isoRegions.contains(where: { $0.identifier == result.country }) else {
                    throw URLError(.cannotParseResponse)
                }
                guard !Task.isCancelled, let self, self.networkGeneration == generation else { return }
                self.snapshot.network = .init(countryCode: result.country, fetchedAt: .now,
                                              city: result.city, subdivision: result.subdivision)
                self.snapshot.networkInvalidated = false
                self.snapshot.networkError = nil
            } catch {
                guard !Task.isCancelled, let self, self.networkGeneration == generation else { return }
                self.snapshot.networkInvalidated = true
                self.snapshot.networkError = .init("出口查询失败，保留上次结果。", "Network lookup failed; the previous observation is retained.")
            }
            guard let self, self.networkGeneration == generation else { return }
            self.isCheckingNetwork = false
            self.networkTask = nil
        }
    }

    @discardableResult
    func launchClaude() async -> Bool {
        guard !isDesignPreview else { return false }
        guard !isLaunching else { return false }
        isLaunching = true
        defer { isLaunching = false }
        operationMessage = nil
        do {
            guard let url = GuardLauncher.installedURL(preferredPath: preferredPath) else { throw GuardLaunchError.notInstalled }
            let launchProfile = profile
            if launchProfile.enabled, !GuardLauncher.runningApplications.isEmpty { throw GuardLaunchError.alreadyRunning }
            let webSession = launchProfile.enabled ? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() : nil
            if webSession != nil { try GuardWebEnvironmentReader.prepareDirectory() }
            let configuration = try GuardLauncher.configuration(profile: launchProfile, webSession: webSession)
            let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
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
        guard !isDesignPreview, !isLaunching else { return false }
        let launchProfile = profile
        isLaunching = true
        defer { isLaunching = false }
        operationMessage = nil
        do {
            guard let url = GuardLauncher.installedURL(preferredPath: preferredPath) else { throw GuardLaunchError.notInstalled }
            let webSession = launchProfile.enabled ? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() : nil
            if webSession != nil { try GuardWebEnvironmentReader.prepareDirectory() }
            let configuration = try GuardLauncher.configuration(profile: launchProfile.enabled ? launchProfile : nil, webSession: webSession)
            var launchedApp: NSRunningApplication?
            try await GuardRestartCoordinator.run(requestExit: {
                let answers = GuardLauncher.runningApplications.map { $0.terminate() }
                return answers.allSatisfy { $0 }
            }, isRunning: { !GuardLauncher.runningApplications.isEmpty }, launch: {
                guard self.profile == launchProfile else { throw GuardRestartError.profileChanged }
                guard GuardLauncher.runningApplications.isEmpty else { throw GuardLaunchError.alreadyRunning }
                launchedApp = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            })
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
        guard profile.enabled, GuardLauncher.runningApplications.isEmpty else { return true }
        return await launchClaude()
    }
}
