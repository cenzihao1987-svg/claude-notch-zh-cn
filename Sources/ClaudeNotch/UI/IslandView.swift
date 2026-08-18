import SwiftUI
import AppKit

/// Top-anchors the pill inside the fixed full-width window, horizontally centered on the notch.
struct IslandRootView: View {
    let model: AppModel
    let presentation: IslandPresentationState

    var body: some View {
        VStack(spacing: 0) {
            IslandView(model: model, presentation: presentation)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The notch-fused black island. Closed: Clawd + session-% flanking the camera. Expanded: it
/// grows into a wider single-page dashboard below the notch. The NotchShape's radii
/// animate, so it morphs like the notch itself growing.
struct IslandView: View {
    let model: AppModel
    let presentation: IslandPresentationState

    /// 5-Hour tile: false = show burn-rate ETA when available, true = always show reset.
    @State private var prefReset = false
    /// The sessions block flips between today's active sessions and all-time top projects on tap.
    @State private var showAllTime = false

    private let wing: CGFloat = 56
    private let iconSize: CGFloat = 18
    private let edgeInset: CGFloat = 12
    private let expandedInset: CGFloat = 24
    private let expandedUsageInset: CGFloat = 32
    private var dropHeight: CGFloat { model.expandedDropHeight }

    private var expanded: Bool { presentation.isExpanded }
    private var closedH: CGFloat { max(presentation.topInset, 30) }
    private var gap: CGFloat { presentation.notchWidth }
    private var closedWidth: CGFloat { wing + gap + wing + edgeInset * 2 }
    private var islandWidth: CGFloat { expanded ? model.expandedIslandWidth : closedWidth }
    private var provider: ProviderUsageSnapshot { model.activeProviderSnapshot }
    private var used: Double { provider.primaryUsage ?? 0 }
    private var displayedUsage: Double { displayFraction(provider.primaryUsage) ?? 0 }
    /// Loaded once — this is read on every render of the closed row, and hitting the disk per
    /// frame during animations would be pure waste. MainActor because NSImage isn't Sendable.
    @MainActor private static let codexIcon: NSImage? = {
        if let resourcesURL = Bundle.main.resourceURL,
           let packagedBundle = Bundle(
               url: resourcesURL.appendingPathComponent("ClaudeNotch_ClaudeNotch.bundle")
           ),
           let url = packagedBundle.url(forResource: "codex", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        guard let url = Bundle.module.url(forResource: "codex", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        let shape = NotchShape(topRadius: 8,
                               bottomRadius: expanded ? 22 : max(10, closedH * 0.40))
        ZStack(alignment: .top) {
            shape.fill(Color.black)
            VStack(spacing: 0) {
                notchRow.frame(width: islandWidth, height: closedH)
                dropDown
                    .frame(width: islandWidth, height: dropHeight, alignment: .top)
                    .opacity(expanded ? 1 : 0)
            }
        }
        .frame(width: islandWidth,
               height: expanded ? closedH + dropHeight : closedH,
               alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .contextMenu { menu }
        .onChange(of: model.selectedProvider) { _, _ in
            showAllTime = false
        }
        .animation(.spring(response: 0.6, dampingFraction: 1.0), value: expanded)
        .animation(.easeInOut(duration: 0.3), value: displayedUsage)
    }

    // Right-click menu (replaces the menu-bar item).
    @ViewBuilder private var menu: some View {
        Menu("用量来源") {
            ForEach(UsageProviderID.allCases) { provider in
                Button {
                    model.selectProvider(provider)
                } label: {
                    if model.selectedProvider == provider {
                        Label(provider.displayName, systemImage: "checkmark")
                    } else {
                        Text(provider.displayName)
                    }
                }
            }
        }
        Menu("图标") {
            ForEach(AvatarStyle.allCases) { style in
                Button {
                    model.setAvatar(style)
                } label: {
                    if model.avatarStyle == style {
                        Label(style.label, systemImage: "checkmark")
                    } else {
                        Text(style.label)
                    }
                }
            }
        }
        Button("立即刷新") { model.refreshNow() }
        Button(model.isPaused ? "恢复监测" : "暂停监测") { model.togglePause() }
        Button((model.animateIcon ? "✓ " : "") + "图标动画") { model.toggleAnimateIcon() }
        Button((model.hideInFullscreen ? "✓ " : "") + "全屏时隐藏") { model.toggleHideInFullscreen() }
        Button((model.showDesktopWidget ? "✓ " : "") + "Codex 桌面小组件") {
            model.toggleDesktopWidget()
        }
        Button((LoginItem.isEnabled ? "✓ " : "") + "开机自启") { LoginItem.toggle() }
        Divider()
        Button("检查更新…") { Updater.shared.checkForUpdates() }
        Divider()
        Button("Claude Notch v\(AppInfo.version) — \(AppInfo.tagline)") {}.disabled(true)
        Divider()
        Button("退出") { NSApp.terminate(nil) }
    }

    // MARK: top row

    private var notchRow: some View {
        ZStack(alignment: .topLeading) {
            ForEach(UsageProviderID.allCases) { item in
                providerButton(item)
                    .position(x: providerPosition(item), y: closedH / 2)
            }
            usageIndicator
                .position(x: usagePosition, y: closedH / 2)
            if !expanded, activityState != .idle {
                activityDot
                    .position(x: collapsedProviderPosition - 16, y: closedH / 2)
                    .transition(.opacity)
            }
        }
    }

    private var collapsedProviderPosition: CGFloat { edgeInset + wing / 2 }

    private func providerPosition(_ item: UsageProviderID) -> CGFloat {
        guard expanded else { return collapsedProviderPosition }
        let index = UsageProviderID.allCases.firstIndex(of: item) ?? 0
        return expandedInset + 16 + CGFloat(index) * 36
    }

    private var usagePosition: CGFloat {
        islandWidth - (expanded ? expandedUsageInset : edgeInset) - wing / 2
    }

    private var activityState: AgentActivityState {
        model.activityState(for: model.selectedProvider)
    }

    private var activityDot: some View {
        let state = activityState
        return Circle()
            .fill(activityColor(state))
            .frame(width: 6, height: 6)
            .overlay(Circle().stroke(Color.black.opacity(0.7), lineWidth: 1))
            .help(state.label)
            .accessibilityLabel("工作状态：\(state.label)")
    }

    private func activityColor(_ state: AgentActivityState) -> Color {
        switch state {
        case .idle: Color.white.opacity(0.34)
        case .working: Color(red: 0.30, green: 0.85, blue: 0.45)
        case .thinking: Color(red: 0.50, green: 0.48, blue: 1.00)
        case .awaitingConfirmation: Color(red: 1.00, green: 0.65, blue: 0.22)
        }
    }

    private func providerButton(_ item: UsageProviderID) -> some View {
        let selected = model.selectedProvider == item
        return providerIcon(for: item)
            .frame(width: iconSize, height: iconSize)
            .frame(width: 32, height: 24)
            .background(expanded && selected ? Color.white.opacity(0.16) : Color.clear, in: Capsule())
            .overlay {
                Capsule().stroke(
                    Color.white.opacity(expanded && selected ? 0.22 : 0), lineWidth: 1
                )
            }
            .opacity(expanded ? (selected ? 1 : 0.42) : (selected ? 1 : 0))
            .allowsHitTesting(expanded || selected)
            .contentShape(Capsule())
            .onTapGesture {
                if expanded { model.selectProvider(item) } else { model.cycleProvider() }
            }
            .help(expanded ? "切换到 \(item.displayName)" : "点击切换用量来源")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.displayName)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var usageIndicator: some View {
        HStack(spacing: 5) {
            Text(displayFraction(provider.primaryUsage).map(Fmt.pct) ?? "—")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white)
            Ring(
                fraction: displayedUsage,
                state: model.selectedProvider == .codex
                    ? remainingRingState(for: displayedUsage)
                    : ringState(for: used),
                lineWidth: 3,
                drainsClockwise: model.selectedProvider == .codex
            )
                .frame(width: 14, height: 14)
        }
        .frame(width: wing, height: closedH)
        .opacity(model.isStale ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture { presentation.isExpanded.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.selectedProvider == .codex ? "Codex 剩余额度" : "Claude 用量")
        .accessibilityValue(displayFraction(provider.primaryUsage).map(Fmt.pct) ?? "未知")
        .accessibilityHint(expanded ? "收起用量卡片" : "展开用量卡片")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func providerIcon(for item: UsageProviderID) -> some View {
        if item == .claude {
            AvatarView(style: model.avatarStyle,
                       active: item == model.selectedProvider && model.animateIcon
                           && !model.isPaused && !model.isAtLimit,
                       urgency: model.iconUrgency)
        } else if let icon = Self.codexIcon {
            CodexIconView(
                image: icon,
                active: item == model.selectedProvider && model.animateIcon
                    && !model.isPaused && !model.isAtLimit,
                urgency: model.iconUrgency
            )
            .opacity(model.isPaused ? 0.45 : 0.9)
        } else if let symbol = NSImage(
            systemSymbolName: item.systemImage,
            accessibilityDescription: item.displayName
        ) {
            Image(nsImage: symbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(model.isPaused ? 0.45 : 0.9))
        } else {
            Text("C")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(model.isPaused ? 0.45 : 0.9))
        }
    }

    // MARK: drop-down — one dashboard page for both providers

    private var contentWidth: CGFloat { model.expandedIslandWidth - expandedInset * 2 }

    private var dropDown: some View {
        singlePage
            .frame(width: contentWidth, height: dropHeight - 15, alignment: .top)
            .padding(.horizontal, expandedInset).padding(.top, 6).padding(.bottom, 9)
    }

    private var singlePage: some View {
        let snapshot = provider
        let stats = singlePageStats
        let tileCount = snapshot.limits.count + stats.count
        let columnCount = tileCount > 4 ? 3 : (tileCount > 2 ? 2 : 1)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
        let summaryWidth: CGFloat = columnCount == 3 ? 380 : 270
        let cellWidth = (summaryWidth - CGFloat(columnCount - 1) * 8) / CGFloat(columnCount)
        let chartWidth = contentWidth - summaryWidth - 8
        let hasStatus = snapshot.statusMessage != nil || model.isStale
        return VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(snapshot.limits) { metric in
                        providerLimitTile(metric).frame(width: cellWidth)
                    }
                    ForEach(stats) { metric in
                        tile(localizedStatLabel(metric), localizedStatValue(metric),
                             height: .compact, sub: metric.subtitle)
                            .frame(width: cellWidth)
                    }
                }
                .frame(width: summaryWidth, height: 136, alignment: .topLeading)
                .opacity(model.isStale ? 0.55 : 1)
                WeekActivityChart(series: snapshot.dailySeries, title: localizedTitle(snapshot.chartTitle))
                    .frame(width: chartWidth, height: 136)
                    .opacity(model.isStale ? 0.55 : 1)
            }
            .frame(width: contentWidth, height: 136, alignment: .topLeading)
            sessionsBlock(limit: hasStatus ? 1 : 2).frame(width: contentWidth)
            if let message = snapshot.statusMessage {
                Text(localizedStatus(message)).font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.20))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1).truncationMode(.tail)
            } else if model.isStale {
                Text("正在重新连接…").font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.20))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: contentWidth, alignment: .topLeading)
    }

    private var singlePageStats: [UsageStatMetric] {
        guard provider.provider == .codex else { return provider.stats }
        var result: [UsageStatMetric] = []
        if let recent = provider.stats.first(where: { $0.id == "tokens-today" })
            ?? provider.stats.first(where: { $0.id == "tokens-yesterday" }) {
            result.append(recent)
        }
        for id in ["credits", "reset", "tokens-lifetime"] {
            if let metric = provider.stats.first(where: { $0.id == id }) { result.append(metric) }
        }
        return result
    }

    // Tap to flip between the provider's primary and alternate session lists when both exist.
    private func sessionsBlock(limit: Int) -> some View {
        let snapshot = provider
        let hasAlternate = snapshot.alternateSessionsTitle != nil
        let showingAlternate = showAllTime && hasAlternate
        let title = localizedTitle(
            showingAlternate ? snapshot.alternateSessionsTitle! : snapshot.sessionsTitle
        )
        let sessions = showingAlternate ? snapshot.alternateSessions : snapshot.sessions
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if hasAlternate {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 8, weight: .semibold))
                        Text(localizedTitle(
                            showingAlternate ? snapshot.sessionsTitle : snapshot.alternateSessionsTitle!
                        ))
                            .font(.system(size: 9, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.09))
                    .clipShape(Capsule())
                }
            }
            if sessions.isEmpty {
                sessionRow("暂无近期活动", cost: nil, tokens: nil, last: nil, muted: true)
            } else {
                ForEach(Array(sessions.prefix(limit))) { session in
                    sessionRow(session.name, cost: session.cost, tokens: session.tokens,
                               last: session.last, muted: false)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { if hasAlternate { showAllTime.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(hasAlternate
            ? "切换到 \(localizedTitle(showingAlternate ? snapshot.sessionsTitle : (snapshot.alternateSessionsTitle ?? "")))"
            : "")
        .accessibilityAddTraits(hasAlternate ? .isButton : [])
        .help(hasAlternate ? "点击切换会话视图" : "近期活动")
    }

    private func sessionRow(_ project: String, cost: Double?, tokens: Int?, last: Date?,
                            muted: Bool) -> some View {
        HStack(spacing: 6) {
            Text(project).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(muted ? 0.5 : 0.85)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if let cost, let tokens {
                (Text(Fmt.usd(cost)).foregroundStyle(.white)
                    + Text("  ·  \(Fmt.tokens(tokens))").foregroundStyle(.white.opacity(0.45)))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else if let tokens {
                Text(Fmt.tokens(tokens)).foregroundStyle(.white)
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            } else if let cost {
                Text(Fmt.usd(cost)).foregroundStyle(.white)
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            } else if let last {
                Text(Fmt.ago(last)).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45)).monospacedDigit()
            } else {
                Text("—").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(minHeight: 20)
    }

    @ViewBuilder private func providerLimitTile(_ metric: UsageLimitMetric) -> some View {
        let isClaudeSession = metric.id == "claude-session"
        let label = localizedLimitLabel(metric.label) + (model.selectedProvider == .codex ? " · 剩余" : "")
        limitTile(label, displayFraction(metric.usedFraction), resets: metric.resetsAt,
                  warningUsage: metric.usedFraction,
                  eta: isClaudeSession && !prefReset ? model.etaToLimit : nil)
            .contentShape(Rectangle())
            .onTapGesture {
                if isClaudeSession, model.etaToLimit != nil { prefReset.toggle() }
            }
    }

    // A limit tile: label, big colour-coded %, and a "resets in …" subline.
    private func limitTile(_ label: String, _ value: Double?, resets: Date?, warningUsage: Double?,
                           eta: TimeInterval? = nil) -> some View {
        tileBox {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Text(value.map(Fmt.pct) ?? "—")
                .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                .foregroundStyle(barColor(warningUsage ?? value ?? 0))
            if let eta {
                Text("约 \(Fmt.dur(eta)) 后触顶")
                    .font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.20))
            } else {
                Text(resets.map { "\(Fmt.until($0)) 后重置" } ?? "重置时间 —")
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
        }
    }

    private func displayFraction(_ usedFraction: Double?) -> Double? {
        guard let usedFraction else { return nil }
        return model.selectedProvider == .codex ? 1 - usedFraction : usedFraction
    }

    enum TileHeight { case compact, tall
        var minHeight: CGFloat { self == .compact ? 64 : 64 }
        var valueSize: CGFloat { self == .compact ? 15 : 17 }
    }

    // A plain value tile, with an optional muted subline (e.g. a projection).
    private func tile(_ label: String, _ value: String, height: TileHeight, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: height.valueSize, weight: .medium)).monospacedDigit()
                .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            if let sub {
                Text(sub).font(.system(size: 9.5)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.4)).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: height.minHeight, alignment: .topLeading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func tileBox<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 1, content: content)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func localizedLimitLabel(_ label: String) -> String {
        let parts = label.components(separatedBy: " · ")
        guard let duration = parts.last else { return label }
        let localizedDuration: String
        switch duration {
        case "5-Hour": localizedDuration = "5 小时"
        case "7-Day": localizedDuration = "7 天"
        case "Daily": localizedDuration = "每日"
        case "Monthly": localizedDuration = "每月"
        case "Annual": localizedDuration = "每年"
        case "Limit": localizedDuration = "额度"
        default:
            if duration.hasSuffix("-Hour"), let value = Int(duration.dropLast(5)) {
                localizedDuration = "\(value) 小时"
            } else if duration.hasSuffix("-Day"), let value = Int(duration.dropLast(4)) {
                localizedDuration = "\(value) 天"
            } else if duration.hasSuffix("-Min"), let value = Int(duration.dropLast(4)) {
                localizedDuration = "\(value) 分钟"
            } else {
                localizedDuration = duration
            }
        }
        guard parts.count > 1 else { return localizedDuration }
        return parts.dropLast().joined(separator: " · ") + " · " + localizedDuration
    }

    private func localizedStatLabel(_ metric: UsageStatMetric) -> String {
        switch metric.id {
        case "tokens-today": "今日 Token · 账号"
        case "tokens-yesterday": "昨日 Token · 账号"
        case "credits": "可用额度"
        // 重置格子不在这里映射：它的 label 随状态变（即将重置 / Tibo 预告 / 距上次重置），
        // 写死一个「重置」会把三个状态全盖掉。末尾的 default 会原样放行。
        case "tokens-lifetime": "Token · 累计"
        case "peak-day": "单日峰值"
        case "longest-task": "最长任务"
        default: metric.label
        }
    }

    private func localizedStatValue(_ metric: UsageStatMetric) -> String {
        if metric.value == "unlimited" { return "无限" }
        if metric.value == "available" { return "可用" }
        if metric.value == "none" { return "无" }
        guard metric.id == "longest-task" else { return metric.value }
        return metric.value.replacingOccurrences(of: "h", with: "小时")
            .replacingOccurrences(of: "m", with: "分")
    }

    private func localizedTitle(_ title: String) -> String {
        switch title {
        case "last 7 days": "近 7 天"
        case "last 7 days · local": "近 7 天 · 本地"
        case "last 7 days · account": "近 7 天 · 账号"
        case "active sessions": "活跃会话"
        case "all-time · top projects": "累计 · 高频项目"
        case "recent tasks": "近期任务"
        default: title
        }
    }

    private func localizedStatus(_ message: String) -> String {
        switch message {
        case "Spend limit reached": "已达消费上限"
        case "Account usage requires ChatGPT sign-in": "需登录 ChatGPT 才能查看账号用量"
        default: message
        }
    }

    private func barColor(_ used: Double) -> Color {
        switch ringState(for: used) {
        case .ok: return .white
        case .warn: return Color(red: 0.96, green: 0.70, blue: 0.20)
        case .critical: return Color(red: 1.00, green: 0.42, blue: 0.42)
        }
    }
}
