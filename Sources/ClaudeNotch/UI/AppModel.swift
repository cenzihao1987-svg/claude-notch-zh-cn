import CodexWidgetShared
import AppKit
import Foundation
import OSLog
import SwiftUI
import WidgetKit

@MainActor @Observable
final class AppModel {
    /// 刷新节奏的可观测性。查看：
    /// `/usr/bin/log show --last 10m --predicate 'subsystem == "com.claudenotch.app"'`
    /// 用 notice 而非 debug —— debug 级别默认根本不记录，等于没有日志。
    /// zsh 下必须写全路径，`log` 是 shell 内建命令，会把系统命令挡掉。
    private static let log = Logger(subsystem: "com.claudenotch.app", category: "refresh")

    private(set) var snapshot: UsageSnapshot = .empty
    private(set) var codexSnapshot: ProviderUsageSnapshot = .unavailable(.codex)
    private(set) var codexWidgetSnapshot = CodexWidgetSnapshotStore.load()
    private(set) var selectedProvider = UsageProviderID(
        rawValue: UserDefaults.standard.string(forKey: "selectedProvider") ?? ""
    ) ?? .claude
    var language: AppLanguage = .saved
    /// 近 24 小时动过的任务及其花费（来自日志），最近活跃的排在前面。
    var recentSessions: [ProjectUsage] { snapshot.recentProjects }
    /// 展开即刷新：折叠态可能刚好停在第 44 秒，展开就是为了看最新的，不该再等一个 tick。
    var isExpanded = false {
        didSet {
            guard isExpanded, oldValue == false else { return }
            refreshSelectedProvider()
        }
    }
    var isPaused = false
    var claudeRunning = false
    var codexRunning = false
    private(set) var activityStates: [UsageProviderID: AgentActivityState] = [:]
    var avatarStyle: AvatarStyle = AvatarStyle.selected
    /// Whether the icon (Clawd / Spark) animates. Persisted; default on.
    var animateIcon: Bool = (UserDefaults.standard.object(forKey: "animateIcon") as? Bool) ?? true
    /// Hide the island while a fullscreen app is frontmost (menu bar hidden). Persisted; default off.
    var hideInFullscreen: Bool = UserDefaults.standard.bool(forKey: "hideInFullscreen")
    /// Keep the Codex quota card on the desktop. Persisted; default on.
    var showDesktopWidget: Bool =
        (UserDefaults.standard.object(forKey: "showDesktopWidget") as? Bool) ?? true
    /// Credential-free by default. The user must explicitly opt in before any Keychain read.
    private(set) var claudeCredentialFallbackEnabled =
        UserDefaults.standard.bool(forKey: "claudeCredentialFallbackEnabled")
    private(set) var claudeWaitingForDesktopUsage = false
    /// Live account limits from claude.ai (authoritative, matches Claude Desktop).
    private(set) var limits: ClaudeLimits?
    /// Context window remaining, 0…1, from the terminal statusline feed (nil if unknown).
    private(set) var contextRemaining: Double?
    /// Friendly plan name, e.g. "Claude Max 5x" (from ~/.claude.json).
    private(set) var planName: String?
    /// Exact Pro/Max capability from Claude Desktop's cached official organization profile.
    private(set) var claudeSubscriptionTier: ClaudeSubscriptionTier?
    private var statuslineUsage: Double?
    private var statuslineWeeklyUsage: Double?
    private var statuslineSessionReset: Date?
    private var statuslineWeeklyReset: Date?
    private var statuslineFetchedAt: Date?
    private var weeklyResetFromConfig: Date?
    /// Recent (time, session %) samples for the burn-rate ETA.
    private var pctHistory: [(t: Date, pct: Double)] = []

    /// Lifetime tokens + cost across every log (scanned off-main, refreshed periodically).
    private(set) var lifetime: LifetimeScanner.Totals = .init()
    /// Local per-day activity for the week chart (scanner data, today overridden live).
    /// Recomputed on each refresh() tick rather than per render.
    private(set) var claudeDailySeries: [DailyUsagePoint] = []

    private let store = UsageStore()
    private let loader = LogLoader()
    private let claudeAPI = ClaudeAPIService()
    private let desktopUsageCache = ClaudeDesktopUsageCache()
    private let codexProvider = CodexUsageProvider()
    private let resetForecastService = CodexResetForecastService()
    private let lifetimeScanner = LifetimeScanner()
    private let activityReader = AgentActivityReader()
    private let handoffCoordinator = HandoffCoordinator()
    private var watcher: LogWatcher?
    private var ticker: Timer?
    private var limitsTimer: Timer?
    private var codexTimer: Timer?
    private var codexWidgetTimer: Timer?
    private var lifetimeTimer: Timer?
    private var activityTimer: Timer?
    private var activityReadInFlight = false
    /// mtime of each log file the last time we parsed it, so the periodic sweep re-reads only
    /// files that actually grew and skips the rest.
    private var parsedMTimes: [URL: Date] = [:]
    /// Byte offset consumed so far per file, so we tail-parse only newly-appended bytes.
    private var parsedOffsets: [URL: UInt64] = [:]
    /// Conversation titles (sessionId → sidebar name), accumulated as logs are parsed.
    private var titlesBySession: [String: String] = [:]
    /// Exact Claude JSONL file for each parsed session. Kept while ingesting so rendering the
    /// recent-session list never has to recursively scan ~/.claude/projects.
    private var transcriptPathsBySession: [String: String] = [:]
    private(set) var handoffStates: [String: HandoffStatus] = [:]
    private var handoffInstructions: [String: String] = [:]
    private var lastReingest = Date.distantPast

    // MARK: display values (official account sources only)

    private var claudeSessionUsage: Double? {
        limits?.sessionPct ?? statuslineUsage
    }
    var sessionUsage: Double? { activeProviderSnapshot.primaryUsage }
    var weeklyUsage: Double? { limits?.weeklyPct ?? statuslineWeeklyUsage }
    var fableUsage: Double? { limits?.fablePct }          // Fable's own weekly limit (if provided)
    var fableResetsAt: Date? { limits?.fableResetsAt }
    var sessionResetsAt: Date? { limits?.sessionResetsAt ?? statuslineSessionReset }
    var weeklyResetsAt: Date? { limits?.weeklyResetsAt ?? statuslineWeeklyReset ?? weeklyResetFromConfig }
    var lastFetch: Date? { limits?.fetchedAt ?? statuslineFetchedAt }
    private var claudeUsageSource: String {
        if let l = limits { return l.source ?? "claude.ai" }
        if statuslineUsage != nil { return "terminal" }
        return "unavailable"
    }
    /// True when live limits exist but haven't refreshed recently (fetches failing) — the UI
    /// dims the numbers so a frozen value is never shown as if it were current.
    var isStale: Bool {
        activeProviderSnapshot.isStale(after: Self.claudeUsageFreshAfter)
    }
    nonisolated static let claudeUsageFreshAfter: TimeInterval = 150

    static func shouldWaitForClaudeDesktopUsage(
        hasCachedUsage: Bool,
        cacheIsFresh: Bool,
        credentialFallbackEnabled: Bool
    ) -> Bool {
        hasCachedUsage ? !cacheIsFresh : !credentialFallbackEnabled
    }

    static func shouldUseClaudeCredentialFallback(
        hasCachedUsage: Bool,
        cacheIsFresh: Bool,
        credentialFallbackEnabled: Bool
    ) -> Bool {
        credentialFallbackEnabled && (!hasCachedUsage || !cacheIsFresh)
    }

    /// Estimated time until the 5-hour limit at the current pace (nil if usage isn't trending
    /// up, or if the block resets first). Uses the slope of session % — no token cap needed.
    var etaToLimit: TimeInterval? {
        guard selectedProvider == .claude else { return nil }
        guard let cur = limits?.sessionPct, cur < 0.999, pctHistory.count >= 2 else { return nil }
        let recent = Array(pctHistory.suffix(8))
        guard let first = recent.first, let last = recent.last else { return nil }
        let dt = last.t.timeIntervalSince(first.t)
        let dpct = last.pct - first.pct
        guard dt > 60, dpct > 0.005 else { return nil }
        let eta = (1.0 - cur) / (dpct / dt)
        if let reset = limits?.sessionResetsAt, eta >= reset.timeIntervalSinceNow { return nil }
        return (eta > 0 && eta < 6 * 3600) ? eta : nil
    }

    /// How urgent the icon should look (0…1) — drives Clawd's walk speed.
    ///
    /// Claude deliberately uses only the 5-hour and 7-day limits, as before multi-provider: the
    /// Fable weekly limit is a per-model cap, and a maxed Fable would otherwise freeze Clawd at
    /// "out of budget" while the account still has plenty of session/weekly headroom.
    var iconUrgency: Double {
        switch selectedProvider {
        case .claude: max(claudeSessionUsage ?? 0, weeklyUsage ?? 0)
        case .codex: codexSnapshot.maximumUsage
        }
    }

    /// A limit (5-hour or 7-day) is used up — there's nothing left to spend, so Clawd stops
    /// walking and stands still rather than sprinting at max speed.
    var isAtLimit: Bool { iconUrgency >= 0.999 }

    /// Credits tile: the purchased usage-credit balance when known (what claude.ai settings calls
    /// "Current balance"), else the monthly spend, else "none".
    private var creditsValue: String {
        if let minor = limits?.creditsBalanceMinor, let currency = limits?.creditsCurrency {
            return Fmt.money(minor: minor, currency: currency)
        }
        if let spend = monthlySpendLabel { return spend }
        return limits?.creditsPct.map {
            language.text("已用 ", "Used ") + Fmt.pct($0)
        } ?? language.text("无", "None")
    }
    /// Subline under the balance: this month's extra-usage spend in absolute money against the
    /// monthly cap. A bare percent read as "percent of my credits" — but it tracks the CAP, so an
    /// emptied balance could sit at "90% used" and look like headroom that isn't there.
    private var creditsSubtitle: String? {
        guard limits?.creditsBalanceMinor != nil else { return nil }
        return monthlySpendLabel.map { $0 + language.text(" / 月", " / month") }
            ?? limits?.creditsPct.map {
                language.text("已用上限的 ", "Used ") + Fmt.pct($0)
                    + language.text("", " of limit")
            }
    }
    /// "€45.21 of €50.00" from the spend block, when the API provides the amounts.
    private var monthlySpendLabel: String? {
        guard let used = limits?.spendUsedMinor, let cap = limits?.spendCapMinor, cap > 0,
              let currency = limits?.spendCurrency else { return nil }
        return language.text(
            "已用 \(Fmt.money(minor: used, currency: currency)) / 上限 \(Fmt.money(minor: cap, currency: currency))",
            "Used \(Fmt.money(minor: used, currency: currency)) / \(Fmt.money(minor: cap, currency: currency)) limit"
        )
    }

    var activeProviderSnapshot: ProviderUsageSnapshot {
        switch selectedProvider {
        case .claude: claudeProviderSnapshot
        case .codex: codexSnapshot
        }
    }

    private var claudeProviderSnapshot: ProviderUsageSnapshot {
        let isPro = claudeSubscriptionTier == .pro
        let isMax = claudeSubscriptionTier == .max
        var usageLimits = [
            UsageLimitMetric(id: "claude-session", label: language.text("5 小时", "5 hours"),
                             usedFraction: claudeSessionUsage, resetsAt: sessionResetsAt),
            UsageLimitMetric(id: "claude-weekly", label: language.text("7 天", "7 days"),
                             usedFraction: weeklyUsage, resetsAt: weeklyResetsAt),
        ]
        if !isPro, fableUsage != nil || isMax {
            usageLimits.append(UsageLimitMetric(id: "claude-fable", label: "Fable",
                                                usedFraction: fableUsage, resetsAt: fableResetsAt))
        }

        var stats: [UsageStatMetric] = []
        if !isPro {
            stats.append(UsageStatMetric(id: "credits", label: language.text("可用额度", "Available credits"),
                                         value: creditsValue, subtitle: creditsSubtitle))
        }

        var currentSessions = recentSessions.map { session in
            let reference = session.cwd.isEmpty ? nil : AgentTaskReference(
                provider: .claude,
                sessionID: session.id,
                title: session.name,
                cwd: session.cwd,
                workspaceRoots: [session.cwd],
                transcriptPath: transcriptPathsBySession[session.id]
            )
            return UsageSessionMetric(id: session.id, name: session.name, cost: nil,
                                      tokens: session.tokens, last: session.last,
                                      taskReference: reference)
        }
        if currentSessions.isEmpty, !snapshot.isEmpty {
            currentSessions.append(UsageSessionMetric(
                id: "claude-active-session",
                name: language.text("当前会话", "Current session"),
                cost: nil,
                tokens: snapshot.activeSessionTokens,
                last: Date()
            ))
        }

        return ProviderUsageSnapshot(
            provider: .claude,
            limits: usageLimits,
            stats: stats,
            todayTokens: snapshot.isEmpty ? nil : snapshot.tokensToday,
            lifetimeTokens: lifetime.tokens == 0 ? nil : lifetime.tokens,
            dailySeries: claudeDailySeries.map {
                DailyUsagePoint(date: $0.date, tokens: $0.tokens)
            },
            chartTitle: language.text("近 7 天 · 本地", "Last 7 days · local"),
            chartOnDetailPage: true,
            sessionsTitle: language.text("近期任务", "Recent tasks"),
            sessions: currentSessions,
            planName: claudeSubscriptionTier == .pro ? "Claude Pro" : planName,
            source: claudeUsageSource,
            fetchedAt: limits?.fetchedAt ?? statuslineFetchedAt,
            statusMessage: claudeWaitingForDesktopUsage
                ? language.text("等待 Claude 客户端更新…", "Waiting for Claude to update…")
                : nil
        )
    }

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var usageFileURL: URL { home.appendingPathComponent(".claude/notch-usage.json") }
    private var configURL: URL { home.appendingPathComponent(".claude.json") }

    func start() {
        CodexWidgetSnapshotStore.saveLanguage(
            language == .english ? .english : .chinese
        )
        readPlanLimits()
        watcher = LogWatcher { [weak self] urls in
            guard let self, !self.isPaused else { return }
            Task { await self.ingest(urls) }
        }
        watcher?.start()
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refreshActivityStates()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshActivityStates() }
        }
        limitsTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshTick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickLimits() }
        }
        codexTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshTick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCodexUsage() }
        }
        codexWidgetTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.selectedProvider != .codex else { return }
                self.fetchCodexUsage(includeWhenInactive: true)
            }
        }
        codexWidgetTimer?.tolerance = 60
        Task.detached(priority: .utility) { [weak self] in
            let files = ClaudePaths.recentLogFiles(within: 2)   // recursive walk stays off-main
            await self?.ingest(files)
        }
        fetchLimits()
        fetchCodexUsage(includeWhenInactive: true)
        scanLifetime()
        lifetimeTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanLifetime() }
        }
    }

    func activityState(for provider: UsageProviderID) -> AgentActivityState {
        guard !isPaused else { return .idle }
        let running = provider == .claude ? claudeRunning : codexRunning
        return running ? (activityStates[provider] ?? .idle) : .idle
    }

    func canHandoff(_ task: AgentTaskReference) -> Bool {
        if case .preparing? = handoffStates[task.id] { return false }
        // 不看 isPaused：守卫是按需 stat 一次文件，不依赖轮询，暂停刷新也照样准。
        return !HandoffActivityGuard.isBusy(task)
    }

    func handoffHelp(_ task: AgentTaskReference) -> String {
        guard canHandoff(task) else {
            return language.text("先停止当前任务再接力", "Stop the current task before handing off")
        }
        return task.destination == .claude
            ? language.text("交给 Claude 桌面端", "Hand off to Claude Desktop")
            : language.text("交给 Codex", "Hand off to Codex")
    }

    func handoffLabel(_ task: AgentTaskReference) -> String {
        if task.destination == .claude {
            return language.text("交给 Claude", "To Claude")
        }
        return language.text("交给 Codex", "To Codex")
    }

    func handoff(_ task: AgentTaskReference) {
        guard canHandoff(task) else { return }
        let awaitingConfirmation = handoffActivityState(for: task.provider) == .awaitingConfirmation
        handoffStates[task.id] = .preparing
        Task { [handoffCoordinator] in
            let result = await handoffCoordinator.handoff(
                task: task,
                to: task.destination,
                awaitingConfirmation: awaitingConfirmation
            )
            switch result {
            case let .opened(destination, _, instruction):
                self.handoffInstructions[task.id] = instruction
                let name = destination == .claude
                    ? self.language.text("Claude 桌面端", "Claude Desktop")
                    : "Codex"
                self.settle(task.id, .opened(
                    self.language.text("已交给 \(name)", "Handed off to \(name)")
                ))
            case let .fallback(_, _, instruction, reason):
                self.handoffInstructions[task.id] = instruction
                self.settle(task.id, .fallback(reason))
            case let .failed(_, instruction, reason):
                self.handoffInstructions[task.id] = instruction
                self.settle(task.id, .failed(reason))
            }
        }
    }

    /// 结果只显示一会儿，然后让位给接力按钮。
    /// 状态一直挂着的话，这一行就再也交接不了第二次了——它把按钮的位置永久占住。
    private func settle(_ taskID: String, _ status: HandoffStatus) {
        handoffStates[taskID] = status
        Task {
            try? await Task.sleep(for: Self.linger(for: status))
            // 期间如果又点了一次、状态已经变了，就别把新状态抹掉。
            guard self.handoffStates[taskID] == status else { return }
            self.handoffStates[taskID] = nil
        }
    }

    /// 成功了没什么可做的，早点把按钮还回来；
    /// 失败或降级要留时间让人看清，还要够悬停过去点「复制交接指令」。
    private static func linger(for status: HandoffStatus) -> Duration {
        if case .opened = status { return .seconds(5) }
        return .seconds(20)
    }

    func canCopyHandoffInstruction(_ task: AgentTaskReference) -> Bool {
        handoffInstructions[task.id] != nil
    }

    func copyHandoffInstruction(_ task: AgentTaskReference) {
        guard let instruction = handoffInstructions[task.id] else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(instruction, forType: .string)
        settle(task.id, .fallback(
            language.text("交接指令已复制", "Handoff instructions copied")
        ))
    }

    /// 只用来判断「有没有待回答的确认」，好把它写进交接包。
    /// 能不能接力由 `HandoffActivityGuard` 按任务自己的记录判断，不看这里。
    private func handoffActivityState(for provider: UsageProviderID) -> AgentActivityState {
        guard !isPaused else { return .idle }
        return activityStates[provider] ?? .idle
    }

    private func refreshActivityStates() {
        guard !activityReadInFlight else { return }
        activityReadInFlight = true
        Task { [activityReader] in
            let states = await activityReader.read()
            self.activityStates = states
            self.activityReadInFlight = false
        }
    }

    /// Total all-time tokens + cost, scanned off-main so the (potentially many-GB) sweep never
    /// blocks the UI.
    private func scanLifetime() {
        Task { [lifetimeScanner] in
            let totals = await lifetimeScanner.scan()
            self.lifetime = totals
        }
    }

    /// Menu action: refetch the selected provider immediately and recompute local state.
    func refreshNow() {
        refresh()
        switch selectedProvider {
        case .claude: fetchLimits(force: true)   // fresh Desktop cache first; network if unavailable/stale
        case .codex: fetchCodexUsage()
        }
    }

    func togglePause() {
        isPaused.toggle()
        if !isPaused {
            refresh()
            fetchLimits()
            fetchCodexUsage()
        }
    }
    /// 立刻拉取当前 provider（不 force，不清缓存、不重读 Keychain）。
    private func refreshSelectedProvider() {
        switch selectedProvider {
        case .claude: fetchLimits()
        case .codex: fetchCodexUsage()
        }
    }
    /// `persist: false` 用于前台跟随的自动切换——只临时生效，不覆盖用户手动选择的记忆。
    func selectProvider(_ provider: UsageProviderID, persist: Bool = true) {
        // 先持久化再判重：自动跟随可能已把 selectedProvider 切成了用户想固定的那个，
        // 此时菜单里再点它一次必须能写进记忆，否则重启会跳回另一个。
        if persist { UserDefaults.standard.set(provider.rawValue, forKey: "selectedProvider") }
        guard provider != selectedProvider else { return }   // 同 App 内换窗口也会触发激活通知
        selectedProvider = provider
        refreshSelectedProvider()
    }
    /// Advance to the next provider (icon click) — with two providers this is a toggle.
    func cycleProvider() {
        let providers = UsageProviderID.allCases
        guard let index = providers.firstIndex(of: selectedProvider) else { return }
        selectProvider(providers[(index + 1) % providers.count])
    }
    func cycleAvatar() { setAvatar(avatarStyle.next) }
    func setAvatar(_ s: AvatarStyle) { avatarStyle = s; AvatarStyle.selected = s }
    func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        language = newLanguage
        newLanguage.save()
        CodexWidgetSnapshotStore.saveLanguage(
            newLanguage == .english ? .english : .chinese
        )
        WidgetCenter.shared.reloadAllTimelines()
    }
    func toggleAnimateIcon() {
        animateIcon.toggle()
        UserDefaults.standard.set(animateIcon, forKey: "animateIcon")
    }
    func toggleHideInFullscreen() {
        hideInFullscreen.toggle()
        UserDefaults.standard.set(hideInFullscreen, forKey: "hideInFullscreen")
    }
    func toggleDesktopWidget() {
        showDesktopWidget.toggle()
        UserDefaults.standard.set(showDesktopWidget, forKey: "showDesktopWidget")
    }
    func toggleClaudeCredentialFallback() {
        claudeCredentialFallbackEnabled.toggle()
        UserDefaults.standard.set(
            claudeCredentialFallbackEnabled,
            forKey: "claudeCredentialFallbackEnabled"
        )
        claudeFailures = 0
        claudeAttemptedAt = nil
        fetchLimits(force: claudeCredentialFallbackEnabled)
    }

    /// 展开态每个 tick 都刷；折叠态至少隔 collapsedInterval 秒才刷一次。
    /// 2026-08-17 先用过 15/45，把账号打到了 api.anthropic.com 的 429，回退到这一档。
    private static let refreshTick: TimeInterval = 30
    private static let collapsedInterval: TimeInterval = 90
    /// 连续失败后的退避上限，与 ClaudeAPIService 里的 900 秒 backoff 同量级。
    private static let maxBackoff: TimeInterval = 900

    /// codex 侧的节流：读本地文件，不会被限流，失败重试无害，所以只看上次成功时刻。
    /// claude 侧不能这么判——见下面 claudeAttemptedAt 的注释。
    private func shouldRefreshCodex(since lastFetch: Date?) -> Bool {
        if isExpanded { return true }
        guard let lastFetch else { return true }
        return Date().timeIntervalSince(lastFetch) >= Self.collapsedInterval
    }

    /// claude 侧记「上次发起请求」的时刻，不是上次成功的时刻。
    /// 用成功时刻做节流会死锁：取数一直失败 → fetchedAt 一直不变 → 每个 tick 都重试 →
    /// 服务端 429 → 继续失败。2026-08-17 就是这样把账号打到限流的。
    /// 这三个成员刻意不写 private——它们是那次事故的根因，要留给 RefreshBackoffTests 钉住。
    var claudeAttemptedAt: Date?
    var claudeFailures = 0
    /// 上一次取数还没回来就别再发。取数可能**无限期**挂住——钥匙串授权框不点，
    /// `SecItemCopyMatching` 就一直等；没有这个标记，挂住期间每 90 秒堆一个 Task，
    /// 用户一点「允许」就会把积压的请求全部发出去，正好又撞限流。
    private var claudeInFlight = false

    /// 距上次发起至少要等多久。连续失败后翻倍退避，压到 maxBackoff 为止。
    var claudeMinGap: TimeInterval {
        guard claudeFailures == 0 else {
            return min(Self.collapsedInterval * pow(2, Double(claudeFailures)), Self.maxBackoff)
        }
        return isExpanded ? Self.refreshTick : Self.collapsedInterval
    }

    /// tick 要先重复一遍 fetch 里的 guard：没有它，未选中的那条线每个 tick 都会打一条
    /// 「刷新了」，而 fetch 进去就被 guard 挡掉——日志记录了不存在的刷新，比没有日志更误导。
    private func tickLimits() {
        guard !isPaused, selectedProvider == .claude else { return }
        fetchLimits()   // 节流与退避都在 fetchLimits 里，这里不再判断
    }

    private func tickCodexUsage() {
        guard !isPaused, selectedProvider == .codex else { return }
        let last = codexSnapshot.fetchedAt
        guard shouldRefreshCodex(since: last) else { return }
        Self.log.notice("codex, \(last.map { Date().timeIntervalSince($0) } ?? -1, privacy: .public)s since last")
        fetchCodexUsage()
    }

    /// Fetch live claude.ai limits off-main (Keychain prompt appears on first run).
    /// Only replaces the last-known-good limits with a response that actually carries a
    /// session %, so a partial/failed read can never clobber correct data.
    ///
    /// 节流放在这里而不是 tickLimits 里，因为定时器只是三个入口之一：展开、前台跟随切换
    /// 也都会立刻调它。切窗口比 tick 频繁得多，只拦定时器等于没拦。
    /// `force` 只给菜单里的「立即刷新」用：新鲜 Desktop 缓存仍优先；缓存不可用或
    /// 过期时才进入网络兜底，自动刷新仍受网络节流与退避保护。
    func fetchLimits(force: Bool = false) {
        guard !isPaused, selectedProvider == .claude else { return }
        // 本地缓存读取也共用 in-flight：避免 30 秒 tick、展开与前台切换同时扫描同一个文件。
        guard !claudeInFlight else { return }
        claudeInFlight = true
        Task { [claudeAPI, desktopUsageCache] in
            defer { self.claudeInFlight = false }

            if let tier = await desktopUsageCache.subscriptionTier() {
                self.claudeSubscriptionTier = tier
            }

            // Claude Desktop 已经请求并缓存的官方响应优先。150 秒内视为新鲜：不再重复请求
            // 同一个接口，也不触碰 token/Cookie/Keychain。仍在当前额度周期内的旧值继续显示并
            // 标为 stale；若已开启凭据兜底，则继续进入受节流与退避保护的网络源。
            if let cached = await desktopUsageCache.latest() {
                if let reset = cached.sessionResetsAt, reset <= Date() {
                    self.discardExpiredDesktopCachedUsage()
                } else {
                    self.applyDesktopCachedUsage(cached)
                    let isFresh = cached.isFresh(after: Self.claudeUsageFreshAfter)
                    self.claudeWaitingForDesktopUsage = Self.shouldWaitForClaudeDesktopUsage(
                        hasCachedUsage: true,
                        cacheIsFresh: isFresh,
                        credentialFallbackEnabled: self.claudeCredentialFallbackEnabled
                    )
                    if isFresh {
                        self.claudeFailures = 0
                        return
                    }
                }
            }

            guard Self.shouldUseClaudeCredentialFallback(
                hasCachedUsage: self.limits != nil,
                cacheIsFresh: false,
                credentialFallbackEnabled: self.claudeCredentialFallbackEnabled
            ) else {
                self.claudeWaitingForDesktopUsage = true
                self.claudeFailures = 0
                return
            }

            let gap = self.claudeAttemptedAt.map { Date().timeIntervalSince($0) } ?? .infinity
            guard force || gap >= self.claudeMinGap else { return }
            self.claudeAttemptedAt = Date()
            Self.log.notice("claude network, \(gap.isFinite ? Int(gap) : -1, privacy: .public)s since last, \(self.claudeFailures, privacy: .public) fails")
            guard let l = await claudeAPI.fetchFromClaudeDesktop(force: force),
                  l.sessionPct != nil else {
                self.claudeFailures += 1
                // 退避要从「失败」起算，不是从「发起」起算。请求本身可能耗掉比退避还长的时间
                // （钥匙串授权框挂了 623 秒），那样退避窗口在请求回来前就被消耗光，
                // 失败后会立刻再发一次。2026-08-17 实跑抓到的。
                self.claudeAttemptedAt = Date()
                Self.log.notice("claude failed \(self.claudeFailures, privacy: .public)x, next in \(Int(self.claudeMinGap), privacy: .public)s")
                return
            }
            self.applyLimits(l)
            self.claudeWaitingForDesktopUsage = false
            self.claudeFailures = 0
        }
    }

    private func applyDesktopCachedUsage(_ cached: ClaudeDesktopCachedUsage) {
        if let current = limits?.fetchedAt, current >= cached.fetchedAt { return }
        let previous = limits
        applyLimits(ClaudeLimits(
            sessionPct: cached.sessionPct,
            sessionResetsAt: cached.sessionResetsAt,
            weeklyPct: cached.weeklyPct,
            weeklyResetsAt: cached.weeklyResetsAt,
            creditsPct: previous?.creditsPct,
            creditsBalanceMinor: previous?.creditsBalanceMinor,
            creditsCurrency: previous?.creditsCurrency,
            spendUsedMinor: previous?.spendUsedMinor,
            spendCapMinor: previous?.spendCapMinor,
            spendCurrency: previous?.spendCurrency,
            fablePct: previous?.fablePct,
            fableResetsAt: previous?.fableResetsAt,
            source: "Claude Desktop cache",
            fetchedAt: cached.fetchedAt
        ))
    }

    private func discardExpiredDesktopCachedUsage() {
        guard limits?.source == "Claude Desktop cache" else { return }
        limits = nil
        pctHistory.removeAll()
    }

    func fetchCodexUsage(includeWhenInactive: Bool = false) {
        guard !isPaused, includeWhenInactive || selectedProvider == .codex else { return }

        // 只在真正在看 Codex 卡片时才碰外部站点。桌面小组件那条每 15 分钟的后台刷新
        // （includeWhenInactive: true）只需要 7 天额度，不该为它发第三方请求。
        if selectedProvider == .codex {
            // 发出去就不管：codex-resets.com 慢 15 秒，也不该让刘海的数字晚 15 秒。
            // 拉到的值落进 actor 缓存，下面这次刷新用的是上一份。真拿到新值时
            // refreshIfStale 返回 true，再触发一次刷新把新值画上去。
            Task { [resetForecastService] in
                if await resetForecastService.refreshIfStale() { self.fetchCodexUsage() }
            }
        }

        Task { [codexProvider, resetForecastService] in
            let forecast = await resetForecastService.current()
            let snapshot = await codexProvider.fetch(forecast: forecast)
            self.codexSnapshot = snapshot
            self.updateCodexWidget(from: snapshot)
        }
    }

    private func updateCodexWidget(from snapshot: ProviderUsageSnapshot) {
        guard let weekly = snapshot.limits.first(where: {
            $0.label.split(separator: "·").last?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "7-Day"
        }), let usedFraction = weekly.usedFraction else { return }
        let widgetSnapshot = CodexWidgetSnapshot(
            remainingFraction: 1 - usedFraction,
            resetsAt: weekly.resetsAt,
            fetchedAt: snapshot.fetchedAt ?? Date()
        )
        codexWidgetSnapshot = widgetSnapshot
        CodexWidgetSnapshotStore.save(widgetSnapshot)
        let systemWidget = Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("CodexQuotaWidget.appex")
        if let systemWidget, FileManager.default.fileExists(atPath: systemWidget.path) {
            WidgetCenter.shared.reloadTimelines(ofKind: "CodexQuotaWidget")
        }
    }

    /// Store new limits and track the % trend for the burn-rate ETA.
    private func applyLimits(_ l: ClaudeLimits) {
        // A new block (reset time jumped later) → clear the ETA trend.
        if let prev = limits?.sessionResetsAt, let now = l.sessionResetsAt,
           now > prev.addingTimeInterval(60) {
            pctHistory.removeAll()
        }
        limits = l
        if let p = l.sessionPct {
            pctHistory.append((Date(), p))
            if pctHistory.count > 20 { pctHistory.removeFirst(pctHistory.count - 20) }
        }
    }

    private func ingest(_ files: [URL]) async {
        let requests = files.map { (url: $0, offset: parsedOffsets[$0] ?? 0) }
        let results = await loader.parse(requests)
        for r in results {
            // A fresh/full read (first time, or after truncation) replaces; a tail read appends.
            if r.reset { store.ingest(fileURL: r.url, events: r.events) }
            else { store.append(fileURL: r.url, events: r.events) }
            parsedOffsets[r.url] = r.newOffset
            for (sid, title) in r.titles { titlesBySession[sid] = title }
            for sessionID in Set(r.events.map(\.sessionId)) {
                transcriptPathsBySession[sessionID] = r.url.path
            }
        }
        for url in files { parsedMTimes[url] = Self.mtime(url) }
        refresh()
    }

    /// Fires every 5s: re-read any grown log files (freshness safety net that doesn't depend on
    /// the FSEvents watcher), then recompute the snapshot.
    private func tick() {
        reingestChangedFiles()
        refresh()
    }

    /// Re-parse recent log files whose mtime advanced since we last read them. This makes local
    /// token/cost stay fresh even if the FSEvents watcher misses an append (e.g. after a launch
    /// with no prior same-day activity). Throttled and mtime-gated so unchanged files are skipped.
    private func reingestChangedFiles() {
        guard !isPaused, Date().timeIntervalSince(lastReingest) >= 10 else { return }
        lastReingest = Date()   // stamped up-front so overlapping sweeps can't stack
        let known = parsedMTimes
        Task.detached(priority: .utility) { [weak self] in
            // The recursive directory walk and the per-file stats run off the MainActor; only
            // the resulting ingest hops back. Large log histories no longer stall the UI.
            let changed = ClaudePaths.recentLogFiles(within: 2)
                .filter { Self.mtime($0) > (known[$0] ?? .distantPast) }
            guard !changed.isEmpty else { return }
            await self?.ingest(changed)
        }
    }

    nonisolated private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    func refresh() {
        snapshot = store.snapshot(now: Date(), titles: titlesBySession)
        readStatusFeed()
        claudeDailySeries = buildClaudeDailySeries()
    }

    /// The scanner aggregates whole days every ten minutes; today's bar is overridden with the
    /// live figures so it never lags. Empty until either source has something to show.
    private func buildClaudeDailySeries() -> [DailyUsagePoint] {
        guard !lifetime.recentDays.isEmpty || !snapshot.isEmpty else { return [] }
        let calendar = Calendar.current
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let now = Date()
        return (0..<7).reversed().compactMap { back in
            // startOfDay so a bar's identity is stable across refreshes (SwiftUI diffs by date).
            guard let raw = calendar.date(byAdding: .day, value: -back, to: now) else { return nil }
            let day = calendar.startOfDay(for: raw)
            let key = f.string(from: day)
            var tokens = lifetime.recentDays[key]?.tokens ?? 0
            var cost = lifetime.recentDays[key]?.cost ?? 0
            if back == 0 {
                tokens = max(tokens, snapshot.tokensToday)
                cost = max(cost, snapshot.costToday)
            }
            return DailyUsagePoint(date: day, tokens: tokens, cost: cost)
        }
    }

    /// Expanded geometry is shared by the SwiftUI shape and its AppKit interaction zone.
    /// Read by both the view and the window's click-zone.
    var expandedDropHeight: CGFloat { 260 }
    var expandedIslandWidth: CGFloat { 720 }

    /// Terminal statusline feed. Claude Code 2.1.80+ officially exposes account rate limits in
    /// `rate_limits`; the legacy flat fields remain a compatibility fallback.
    private func readStatusFeed() {
        guard let data = try? Data(contentsOf: usageFileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let rateLimits = obj["rate_limits"] as? [String: Any] {
            func readWindow(_ key: String) -> (Double?, Date?) {
                guard let window = rateLimits[key] as? [String: Any] else { return (nil, nil) }
                let rawPct: Double? = (window["used_percentage"] as? NSNumber)?.doubleValue
                let pct = rawPct.map { min(1, max(0, $0 / 100)) }
                let reset = (window["resets_at"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue)
                }
                return (pct, reset)
            }
            (statuslineUsage, statuslineSessionReset) = readWindow("five_hour")
            (statuslineWeeklyUsage, statuslineWeeklyReset) = readWindow("seven_day")
            statuslineFetchedAt = Self.mtime(usageFileURL)
        } else if let rem = (obj["rate_remaining"] as? NSNumber)?.doubleValue {
            statuslineUsage = max(0, min(1, (100 - rem) / 100))
            statuslineFetchedAt = Self.mtime(usageFileURL)
        }
        if let ctx = (obj["ctx_remaining"] as? NSNumber)?.doubleValue {
            contextRemaining = max(0, min(1, ctx / 100))
        }
    }

    /// Weekly reset fallback from ~/.claude.json (used only until the live fetch lands).
    private func readPlanLimits() {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let gb = root["cachedGrowthBookFeatures"] as? [String: Any],
           let lattice = gb["tengu_saffron_lattice"] as? [String: Any],
           let iso = lattice["planLimitsEndDate"] as? String {
            weeklyResetFromConfig = ISO8601DateFormatter().date(from: iso)
        }
        if let oauth = root["oauthAccount"] as? [String: Any],
           let tier = oauth["organizationRateLimitTier"] as? String {
            planName = Fmt.planLabel(tier)
        }
    }
}
