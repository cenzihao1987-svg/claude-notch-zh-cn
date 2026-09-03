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

private struct HandoffSessionRow: View {
    let project: String
    let cost: Double?
    let tokens: Int?
    let last: Date?
    let muted: Bool
    let task: AgentTaskReference?
    let status: HandoffStatus?
    let canHandoff: Bool
    let canCopy: Bool
    let handoffLabel: String
    let handoffDestinations: [HandoffDestination]
    let destinationLabel: (HandoffDestination) -> String
    let help: String
    let language: AppLanguage
    let onHandoff: (HandoffDestination) -> Void
    let onCopy: () -> Void

    @State private var isHovering = false
    @State private var showsHandoffMenu = false

    var body: some View {
        HStack(spacing: 6) {
            Text(project)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(muted ? 0.5 : 0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let status, isHovering, canCopy, statusAllowsCopy(status) {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.plain)
                .help(language.text("复制交接指令", "Copy handoff instructions"))
                .accessibilityLabel(language.text("复制交接指令", "Copy handoff instructions"))
            } else if let status {
                statusView(status)
            } else if task != nil, isHovering || showsHandoffMenu {
                Button {
                    showsHandoffMenu = true
                } label: {
                    handoffButton
                }
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(!canHandoff)
                .help(help)
                .accessibilityLabel(help)
                .popover(isPresented: $showsHandoffMenu, arrowEdge: .bottom) {
                    handoffDestinationMenu
                }
            } else {
                sessionMetadata
            }
        }
        // 接力胶囊本身是 22pt；行也固定为同一高度，悬停替换右侧内容时不会推挤整张列表。
        .frame(height: 22)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var handoffButton: some View {
        HStack(spacing: 5) {
            Text(handoffLabel)
            Image(systemName: "arrow.right.circle.fill")
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white.opacity(canHandoff ? 0.92 : 0.35))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Color.white.opacity(canHandoff ? 0.10 : 0.05))
        .clipShape(Capsule())
        .overlay {
            Capsule().stroke(Color.white.opacity(canHandoff ? 0.12 : 0.06), lineWidth: 0.5)
        }
    }

    private var handoffDestinationMenu: some View {
        VStack(spacing: 2) {
            ForEach(handoffDestinations, id: \.self) { destination in
                Button {
                    showsHandoffMenu = false
                    onHandoff(destination)
                } label: {
                    Text(destinationLabel(destination))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 190)
    }

    @ViewBuilder private func statusView(_ status: HandoffStatus) -> some View {
        HStack(spacing: 5) {
            if case .preparing = status {
                ProgressView().controlSize(.mini).tint(.white.opacity(0.75))
            }
            Text(statusMessage(status))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(statusColor(status))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190, alignment: .trailing)
        }
        .help(statusMessage(status))
        .accessibilityLabel(statusMessage(status))
    }

    @ViewBuilder private var sessionMetadata: some View {
        if let cost, let tokens {
            (Text(Fmt.usd(cost)).foregroundStyle(.white)
                + Text("  ·  \(Fmt.tokens(tokens))").foregroundStyle(.white.opacity(0.45)))
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        } else if let tokens {
            HStack(spacing: 6) {
                if let last {
                    Text(Fmt.ago(last, language: language)).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Text(Fmt.tokens(tokens)).foregroundStyle(.white)
                    .font(.system(size: 12, weight: .semibold))
            }
            .monospacedDigit().lineLimit(1)
        } else if let cost {
            Text(Fmt.usd(cost)).foregroundStyle(.white)
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
        } else if let last {
            Text(Fmt.ago(last, language: language)).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45)).monospacedDigit()
        } else {
            Text("—").font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    private func statusColor(_ status: HandoffStatus) -> Color {
        switch status {
        case .preparing: .white.opacity(0.65)
        case .opened: Color(red: 0.30, green: 0.85, blue: 0.45)
        case .fallback: Color(red: 1.00, green: 0.65, blue: 0.22)
        case .failed: Color(red: 1.00, green: 0.42, blue: 0.42)
        }
    }

    private func statusMessage(_ status: HandoffStatus) -> String {
        if case .preparing = status {
            return language.text("正在整理…", "Preparing…")
        }
        guard language == .english else { return status.message }
        switch status.message {
        case "无法生成交接包": return "Could not create the handoff packet"
        case "Claude 桌面端深链未打开，交接指令已复制":
            return "Claude Desktop did not open; instructions copied"
        case "Codex 任务未创建": return "Codex task was not created"
        case "Codex 任务已创建但深链未打开，交接指令已复制":
            return "Codex task created; link did not open; instructions copied"
        case "未找到 WorkBuddy，交接指令已复制":
            return "WorkBuddy was not found; instructions copied"
        case "WorkBuddy 深链未打开，交接指令已复制":
            return "WorkBuddy did not open; instructions copied"
        case "交接指令已复制": return "Handoff instructions copied"
        case "未找到 Codex": return "Codex was not found"
        case "Codex 本地接口响应超时": return "Codex timed out"
        case "Codex 本地接口已断开": return "Codex connection closed"
        default:
            if status.message.hasPrefix("交接包保存失败：") {
                return status.message.replacingOccurrences(
                    of: "交接包保存失败：",
                    with: "Could not save handoff packet: "
                )
            }
            if status.message.hasPrefix("Codex 启动失败：") {
                return status.message.replacingOccurrences(
                    of: "Codex 启动失败：",
                    with: "Could not start Codex: "
                )
            }
            return status.message
        }
    }

    private func statusAllowsCopy(_ status: HandoffStatus) -> Bool {
        switch status {
        case .fallback, .failed: true
        case .preparing, .opened: false
        }
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
    private let closedUsageInset: CGFloat = 20
    private let expandedInset: CGFloat = 24
    private let expandedUsageInset: CGFloat = 32
    private var dropHeight: CGFloat { model.expandedDropHeight }

    private var expanded: Bool { presentation.isExpanded }
    private var closedH: CGFloat { max(presentation.topInset, 30) }
    private var gap: CGFloat { presentation.notchWidth }
    private var closedWidth: CGFloat { wing + gap + wing + edgeInset * 2 }
    private var islandWidth: CGFloat { expanded ? model.expandedIslandWidth : closedWidth }
    private var provider: ProviderUsageSnapshot { model.activeProviderSnapshot }
    private var language: AppLanguage { model.language }
    private var used: Double { provider.primaryUsage ?? 0 }
    private var displayedUsage: Double { displayFraction(provider.primaryUsage) ?? 0 }
    private var usageAreaWidth: CGFloat {
        guard expanded else { return wing }
        return provider.headlineValue == nil ? 88 : 112
    }
    /// Loaded once — this is read on every render of the closed row, and hitting the disk per
    /// frame during animations would be pure waste. MainActor because NSImage isn't Sendable.
    @MainActor private static let codexIcon: NSImage? = {
        resourceImage(named: "codex")
    }()
    @MainActor private static let openAIIcon: NSImage? = {
        guard let icon = resourceImage(named: "openai") else { return nil }
        icon.isTemplate = true
        return icon
    }()
    @MainActor private static let deepSeekIcon: NSImage? = {
        guard let source = resourceImage(named: "deepseek") else { return nil }
        let icon = NSImage(size: NSSize(width: 205, height: 165))
        icon.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: icon.size),
            from: NSRect(x: 0, y: 0, width: 205, height: 165),
            operation: .sourceOver,
            fraction: 1
        )
        icon.unlockFocus()
        icon.isTemplate = true
        return icon
    }()
    @MainActor private static let workBuddyIcon: NSImage? = {
        guard let icon = resourceImage(named: "workbuddy") else { return nil }
        icon.isTemplate = true
        return icon
    }()

    @MainActor private static func resourceImage(named name: String) -> NSImage? {
        if let resourcesURL = Bundle.main.resourceURL,
           let packagedBundle = Bundle(
               url: resourcesURL.appendingPathComponent("ClaudeNotch_ClaudeNotch.bundle")
           ),
           let url = packagedBundle.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        guard let url = Bundle.module.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

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
        .onChange(of: model.selectedProvider) { _, _ in
            showAllTime = false
        }
        .animation(.spring(response: 0.6, dampingFraction: 1.0), value: expanded)
        .animation(.easeInOut(duration: 0.3), value: displayedUsage)
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
        islandWidth - (expanded ? 16 : closedUsageInset) - usageAreaWidth / 2
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
            .help(activityLabel(state))
            .accessibilityLabel(language.text(
                "工作状态：\(activityLabel(state))",
                "Work status: \(activityLabel(state))"
            ))
    }

    private func activityColor(_ state: AgentActivityState) -> Color {
        switch state {
        case .idle: Color.white.opacity(0.34)
        case .working: Color(red: 0.30, green: 0.85, blue: 0.45)
        case .thinking: Color(red: 0.50, green: 0.48, blue: 1.00)
        case .awaitingConfirmation: Color(red: 1.00, green: 0.65, blue: 0.22)
        }
    }

    private func activityLabel(_ state: AgentActivityState) -> String {
        switch state {
        case .idle: language.text("空闲", "Idle")
        case .working: language.text("工作中", "Working")
        case .thinking: language.text("思考中", "Thinking")
        case .awaitingConfirmation: language.text("待确认", "Awaiting confirmation")
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
            .help(expanded
                ? language.text("切换到 \(item.displayName)", "Switch to \(item.displayName)")
                : language.text("点击切换用量来源", "Click to switch usage source"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.displayName)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var usageIndicator: some View {
        HStack(spacing: expanded ? 8 : 5) {
            usageSummary
            if expanded {
                settingsButton
            }
        }
        .frame(width: usageAreaWidth, height: closedH, alignment: .trailing)
        .opacity(model.isStale ? 0.5 : 1)
    }

    private var usageSummary: some View {
        Group {
            if let headline = provider.headlineValue {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
            } else {
                HStack(spacing: 5) {
                    Text(displayFraction(provider.primaryUsage).map(Fmt.pct) ?? "—")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                    Ring(
                        fraction: displayedUsage,
                        state: showsRemainingUsage
                            ? remainingRingState(for: displayedUsage)
                            : ringState(for: used),
                        lineWidth: 3,
                        drainsClockwise: showsRemainingUsage
                    )
                        .frame(width: 14, height: 14)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { presentation.isExpanded.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usageAccessibilityLabel)
        .accessibilityValue(provider.headlineValue ?? displayFraction(provider.primaryUsage).map(Fmt.pct)
            ?? language.text("未知", "Unknown"))
        .accessibilityHint(expanded
            ? language.text("收起用量卡片", "Collapse usage card")
            : language.text("展开用量卡片", "Expand usage card"))
        .accessibilityAddTraits(.isButton)
    }

    private var settingsButton: some View {
        Button {
            SettingsWindow.present(model: model)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.10), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(language.text("设置", "Settings"))
        .accessibilityLabel(language.text("设置", "Settings"))
        .accessibilityHint(language.text(
            "打开 Claude Notch 设置窗口",
            "Open the Claude Notch settings window"
        ))
    }

    @ViewBuilder private func providerIcon(for item: UsageProviderID) -> some View {
        if item == .claude {
            AvatarView(style: model.avatarStyle,
                       active: item == model.selectedProvider && model.animateIcon
                           && !model.isPaused && !model.isAtLimit,
                       urgency: model.iconUrgency)
        } else if item == .codex,
                  let icon = model.avatarStyle == .spark ? Self.openAIIcon : Self.codexIcon {
            CodexIconView(
                image: icon,
                active: item == model.selectedProvider && model.animateIcon
                    && !model.isPaused && !model.isAtLimit,
                urgency: model.iconUrgency
            )
            .foregroundStyle(.white.opacity(model.isPaused ? 0.45 : 0.9))
            .opacity(model.isPaused ? 0.45 : 0.9)
        } else if item == .deepseek, let icon = Self.deepSeekIcon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(model.isPaused ? 0.45 : 0.9))
        } else if item == .workbuddy, let icon = Self.workBuddyIcon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(model.isPaused ? 0.45 : 0.9))
                .opacity(model.isPaused ? 0.45 : 1)
        } else if let symbol = NSImage(
            systemSymbolName: item.systemImage,
            accessibilityDescription: item.displayName
        ) {
            Image(nsImage: symbol)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white.opacity(model.isPaused ? 0.45 : 0.9))
        } else {
            Text(item == .deepseek ? "D" : "C")
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

    @ViewBuilder private var singlePage: some View {
        if provider.provider == .deepseek {
            deepSeekPage
        } else if provider.provider == .workbuddy {
            workBuddyPage
        } else {
            providerDashboard
        }
    }

    private var providerDashboard: some View {
        let snapshot = provider
        let limits = Self.singlePageLimits(for: snapshot)
        let stats = Self.singlePageStats(for: snapshot)
        let tileCount = limits.count + stats.count
        let columnCount = snapshot.provider == .codex ? 2 : (tileCount > 4 ? 3 : (tileCount > 2 ? 2 : 1))
        let summaryWidth: CGFloat = columnCount == 3 ? 380 : 270
        let chartWidth = contentWidth - summaryWidth - 8
        let summaryItems = limits.map(SummaryTileItem.limit) + stats.map(SummaryTileItem.stat)
        return VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                summaryGrid(items: summaryItems, columnCount: columnCount)
                .frame(width: summaryWidth, height: 136, alignment: .topLeading)
                .opacity(model.isStale ? 0.55 : 1)
                WeekActivityChart(
                    series: snapshot.dailySeries,
                    title: localizedTitle(snapshot.chartTitle),
                    language: language,
                    note: snapshot.dailySeries.contains { $0.modelUsage != nil }
                        ? language.text("最多延迟 6 小时", "up to 6 h delay")
                        : nil
                )
                    .frame(width: chartWidth, height: 136)
                    .opacity(model.isStale ? 0.55 : 1)
            }
            .frame(width: contentWidth, height: 136, alignment: .topLeading)
            .padding(.bottom, 4)
            sessionsBlock(limit: AppModel.expandedTaskLimit).frame(width: contentWidth)
            if let message = snapshot.statusMessage {
                Text(localizedStatus(message)).font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.20))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1).truncationMode(.tail)
            } else if model.isStale {
                Text(language.text("正在重新连接…", "Reconnecting…")).font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.20))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: contentWidth, alignment: .topLeading)
    }

    private var deepSeekPage: some View {
        let snapshot = provider
        let stats = Self.singlePageStats(for: snapshot)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
        let summaryWidth: CGFloat = 278
        let cellWidth = (summaryWidth - 8) / 2
        let chartWidth = contentWidth - summaryWidth - 8
        return VStack(alignment: .leading, spacing: 8) {
            if stats.isEmpty {
                tile(language.text("DeepSeek 状态", "DeepSeek status"),
                     localizedStatus(snapshot.statusMessage ?? "未找到 DeepSeek 配置"),
                     height: .compact)
                    .frame(width: contentWidth)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(stats) { metric in
                            statTile(metric).frame(width: cellWidth)
                        }
                    }
                    .frame(width: summaryWidth, height: 136, alignment: .topLeading)
                    if let history = model.deepSeekSpendHistory {
                        WeekActivityChart(
                            series: history.lastSevenDays(),
                            title: language.text("近 7 天 · 消费", "Last 7 days · spend"),
                            language: language,
                            currency: history.currency
                        )
                        .frame(width: chartWidth, height: 136)
                    } else {
                        tile(language.text("近 7 天消费", "Last 7 days · spend"),
                             language.text("等待自动读取“下载”中的最新导出", "Waiting for the latest export in Downloads"),
                             height: .compact)
                            .frame(width: chartWidth, height: 136)
                    }
                }
                .frame(width: contentWidth, height: 136, alignment: .topLeading)
                .opacity(model.isStale ? 0.55 : 1)
            }
            Text(deepSeekFooter(snapshot))
                .font(.system(size: 10))
                .foregroundStyle(snapshot.statusMessage == nil && model.deepSeekSpendError == nil
                    ? .white.opacity(0.45)
                    : Color(red: 0.96, green: 0.70, blue: 0.20))
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(width: contentWidth, alignment: .topLeading)
    }

    private var workBuddyPage: some View {
        let snapshot = provider
        let items = snapshot.stats.map(SummaryTileItem.stat)
        let summaryWidth: CGFloat = 270
        let chartWidth = contentWidth - summaryWidth - 8
        return VStack(alignment: .leading, spacing: 8) {
            if items.isEmpty {
                tile(language.text("WorkBuddy 状态", "WorkBuddy status"),
                     localizedStatus(snapshot.statusMessage ?? "未找到 WorkBuddy 数据"), height: .compact)
                    .frame(width: contentWidth, height: 136)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    summaryGrid(items: items, columnCount: 2)
                        .frame(width: summaryWidth, height: 136, alignment: .topLeading)
                    if snapshot.dailySeries.isEmpty {
                        tile(language.text("近 7 天 · 本机消耗", "Last 7 days · local usage"),
                             language.text("无法读取 WorkBuddy 本机积分记录",
                                           "Unable to read local WorkBuddy credit records"),
                             height: .compact)
                            .frame(width: chartWidth, height: 136)
                    } else {
                        WeekActivityChart(
                            series: snapshot.dailySeries,
                            title: localizedTitle(snapshot.chartTitle),
                            language: language
                        )
                        .frame(width: chartWidth, height: 136)
                    }
                }
                .frame(width: contentWidth, height: 136, alignment: .topLeading)
                    .opacity(model.isStale ? 0.55 : 1)
            }
            sessionsBlock(limit: AppModel.expandedTaskLimit).frame(width: contentWidth)
            if let message = snapshot.statusMessage {
                Text(localizedStatus(message)).font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.20))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1).truncationMode(.tail)
            } else if model.isStale {
                Text(language.text("正在重新连接…", "Reconnecting…")).font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.20))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: contentWidth, alignment: .topLeading)
    }

    private func deepSeekFooter(_ snapshot: ProviderUsageSnapshot) -> String {
        if let message = snapshot.statusMessage { return localizedStatus(message) }
        if let message = model.deepSeekSpendError { return localizedStatus(message) }
        if let history = model.deepSeekSpendHistory {
            let name = URL(fileURLWithPath: history.sourcePath).lastPathComponent
            return language.text("用量 CSV：\(name)", "Usage CSV: \(name)")
        }
        return language.text("每天 09:00、21:00 自动读取“下载”中的最新导出", "Automatically reads the latest download at 09:00 and 21:00")
    }

    static func singlePageLimits(for snapshot: ProviderUsageSnapshot) -> [UsageLimitMetric] {
        guard snapshot.provider == .codex else { return snapshot.limits }
        return Array(snapshot.limits.filter { metric in
            let identity = "\(metric.id) \(metric.label)".lowercased()
            return !identity.contains("gpt")
        }.prefix(2))
    }

    static func singlePageStats(for snapshot: ProviderUsageSnapshot) -> [UsageStatMetric] {
        guard snapshot.provider == .codex else { return snapshot.stats }
        var result: [UsageStatMetric] = []
        // Codex 摘要固定 2×2：两个主额度 + 可用额度 + 重置/Tibo。
        // Token 日消耗仍保留在数据与周图中，不再占摘要卡位。
        for id in ["credits", "reset"] {
            if let metric = snapshot.stats.first(where: { $0.id == id }) { result.append(metric) }
        }
        return result
    }

    static func summaryRowItemCounts(itemCount: Int, columnCount: Int) -> [Int] {
        guard itemCount > 0, columnCount > 0 else { return [] }
        return stride(from: 0, to: itemCount, by: columnCount).map {
            min(columnCount, itemCount - $0)
        }
    }

    private var usageAccessibilityLabel: String {
        switch model.selectedProvider {
        case .claude: language.text("Claude 用量", "Claude usage")
        case .codex: language.text("Codex 剩余额度", "Codex remaining quota")
        case .workbuddy: language.text("WorkBuddy 剩余积分", "WorkBuddy remaining credits")
        case .deepseek: language.text("DeepSeek 剩余余额", "DeepSeek remaining balance")
        }
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
            .contentShape(Rectangle())
            .onTapGesture { if hasAlternate { showAllTime.toggle() } }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityHint(hasAlternate
                ? language.text(
                    "切换到 \(localizedTitle(showingAlternate ? snapshot.sessionsTitle : (snapshot.alternateSessionsTitle ?? "")))",
                    "Switch to \(localizedTitle(showingAlternate ? snapshot.sessionsTitle : (snapshot.alternateSessionsTitle ?? "")))"
                )
                : "")
            .accessibilityAddTraits(hasAlternate ? .isButton : [])
            .help(hasAlternate
                ? language.text("点击切换会话视图", "Click to switch task view")
                : language.text("近期活动", "Recent activity"))
            if sessions.isEmpty {
                sessionRow(nil, placeholder: language.text("暂无近期活动", "No recent activity"), muted: true)
            } else {
                ForEach(Array(sessions.prefix(limit))) { session in
                    sessionRow(session, placeholder: "", muted: false)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func sessionRow(_ session: UsageSessionMetric?, placeholder: String,
                            muted: Bool) -> some View {
        let task = session?.taskReference
        let project: String
        if session?.name == "Untitled task" {
            project = language.text("未命名任务", "Untitled task")
        } else {
            project = session?.name ?? placeholder
        }
        return HandoffSessionRow(
            project: project,
            cost: session?.cost,
            tokens: session?.tokens,
            last: session?.last,
            muted: muted,
            task: task,
            status: task.flatMap { model.handoffStates[$0.id] },
            canHandoff: task.map(model.canHandoff) ?? false,
            canCopy: task.map(model.canCopyHandoffInstruction) ?? false,
            handoffLabel: task == nil ? "" : model.handoffLabel(),
            handoffDestinations: task?.handoffDestinations ?? [],
            destinationLabel: model.handoffDestinationLabel,
            help: task.map(model.handoffHelp) ?? "",
            language: language,
            onHandoff: { destination in
                if let task { model.handoff(task, to: destination) }
            },
            onCopy: { if let task { model.copyHandoffInstruction(task) } }
        )
    }

    private enum SummaryTileItem: Identifiable {
        case limit(UsageLimitMetric)
        case stat(UsageStatMetric)

        var id: String {
            switch self {
            case let .limit(metric): "limit-\(metric.id)"
            case let .stat(metric): "stat-\(metric.id)"
            }
        }
    }

    private func summaryGrid(
        items: [SummaryTileItem],
        columnCount: Int,
        height: CGFloat = 136
    ) -> some View {
        let rowCounts = Self.summaryRowItemCounts(
            itemCount: items.count,
            columnCount: columnCount
        )
        let rowHeight = rowCounts.isEmpty
            ? height
            : (height - CGFloat(rowCounts.count - 1) * 8) / CGFloat(rowCounts.count)
        return VStack(spacing: 8) {
            ForEach(rowCounts.indices, id: \.self) { rowIndex in
                let start = rowIndex * columnCount
                let end = start + rowCounts[rowIndex]
                HStack(spacing: 8) {
                    ForEach(Array(items[start..<end])) { item in
                        summaryTile(item, minHeight: rowHeight)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder private func summaryTile(_ item: SummaryTileItem, minHeight: CGFloat) -> some View {
        switch item {
        case let .limit(metric):
            providerLimitTile(metric, minHeight: minHeight)
        case let .stat(metric):
            statTile(metric, minHeight: minHeight)
        }
    }

    @ViewBuilder private func providerLimitTile(
        _ metric: UsageLimitMetric,
        minHeight: CGFloat = 64
    ) -> some View {
        let isClaudeSession = metric.id == "claude-session"
        let label = localizedLimitLabel(metric.label) + (showsRemainingUsage
            ? language.text(" · 剩余", " · remaining")
            : "")
        limitTile(label, displayFraction(metric.usedFraction), resets: metric.resetsAt,
                  warningUsage: metric.usedFraction,
                  eta: isClaudeSession && !prefReset ? model.etaToLimit : nil,
                  minHeight: minHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                if isClaudeSession, model.etaToLimit != nil { prefReset.toggle() }
            }
    }

    // A limit tile: label, big colour-coded %, and a "resets in …" subline.
    private func limitTile(_ label: String, _ value: Double?, resets: Date?, warningUsage: Double?,
                           eta: TimeInterval? = nil, minHeight: CGFloat = 64) -> some View {
        tileBox(minHeight: minHeight) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Text(value.map(Fmt.pct) ?? "—")
                .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                .foregroundStyle(barColor(warningUsage ?? value ?? 0))
            if let eta {
                Text(language.text(
                    "约 \(Fmt.dur(eta, language: language)) 后触顶",
                    "Limit in about \(Fmt.dur(eta, language: language))"
                ))
                    .font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                    .foregroundStyle(Color(red: 0.96, green: 0.70, blue: 0.20))
            } else {
                Text(resets.map {
                    language.text(
                        "\(Fmt.until($0, language: language)) 后重置",
                        "Resets in \(Fmt.until($0, language: language))"
                    )
                } ?? language.text("重置时间 —", "Reset time —"))
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
        }
    }

    private func displayFraction(_ usedFraction: Double?) -> Double? {
        guard let usedFraction else { return nil }
        return showsRemainingUsage ? 1 - usedFraction : usedFraction
    }

    private var showsRemainingUsage: Bool {
        model.selectedProvider == .codex || model.selectedProvider == .workbuddy
    }

    enum TileHeight { case compact, tall
        var minHeight: CGFloat { self == .compact ? 64 : 64 }
        var valueSize: CGFloat { self == .compact ? 15 : 17 }
    }

    // A plain value tile, with an optional muted subline (e.g. a projection).
    private func tile(
        _ label: String,
        _ value: String,
        height: TileHeight,
        sub: String? = nil,
        minHeight: CGFloat? = nil
    ) -> some View {
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
        .frame(maxWidth: .infinity,
               minHeight: minHeight ?? height.minHeight,
               alignment: .topLeading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func statTile(
        _ metric: UsageStatMetric,
        minHeight: CGFloat = 64
    ) -> some View {
        if metric.id == "reset" {
            Link(destination: CodexResetSource.websiteURL) {
                tile(localizedStatLabel(metric), localizedStatValue(metric),
                     height: .compact, sub: localizedStatSubtitle(metric), minHeight: minHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(language.text("打开 codex-resets.com", "Open codex-resets.com"))
            .accessibilityHint(language.text(
                "在浏览器中查看 Codex 重置详情",
                "View Codex reset details in your browser"
            ))
        } else {
            tile(localizedStatLabel(metric), localizedStatValue(metric),
                 height: .compact, sub: localizedStatSubtitle(metric), minHeight: minHeight)
        }
    }

    private func tileBox<C: View>(
        minHeight: CGFloat = 64,
        @ViewBuilder _ content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 1, content: content)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func localizedLimitLabel(_ label: String) -> String {
        let parts = label.components(separatedBy: " · ")
        guard let duration = parts.last else { return label }
        let localizedDuration: String
        switch duration {
        case "5-Hour", "5 小时", "5 hours":
            localizedDuration = language.text("5 小时", "5 hours")
        case "7-Day", "7 天", "7 days":
            localizedDuration = language.text("7 天", "7 days")
        case "Daily", "每日": localizedDuration = language.text("每日", "Daily")
        case "Monthly", "每月": localizedDuration = language.text("每月", "Monthly")
        case "Annual", "每年": localizedDuration = language.text("每年", "Annual")
        case "Limit", "额度": localizedDuration = language.text("额度", "Limit")
        case "credits": localizedDuration = language.text("积分", "Credits")
        default:
            if duration.hasSuffix("-Hour"), let value = Int(duration.dropLast(5)) {
                localizedDuration = language.text("\(value) 小时", "\(value) hours")
            } else if duration.hasSuffix("-Day"), let value = Int(duration.dropLast(4)) {
                localizedDuration = language.text("\(value) 天", "\(value) days")
            } else if duration.hasSuffix("-Min"), let value = Int(duration.dropLast(4)) {
                localizedDuration = language.text("\(value) 分钟", "\(value) minutes")
            } else {
                localizedDuration = duration
            }
        }
        guard parts.count > 1 else { return localizedDuration }
        return parts.dropLast().joined(separator: " · ") + " · " + localizedDuration
    }

    private func localizedStatLabel(_ metric: UsageStatMetric) -> String {
        switch metric.id {
        case "deepseek-total-balance": language.text("总可用余额", "Total balance")
        case "deepseek-topped-up-balance": language.text("充值余额", "Topped-up balance")
        case "deepseek-granted-balance": language.text("赠金余额", "Granted balance")
        case "deepseek-api-status": language.text("API 状态", "API status")
        case "workbuddy-remaining": language.text("剩余积分", "Remaining credits")
        case "workbuddy-used": language.text("已用积分", "Used credits")
        case "workbuddy-plan": language.text("当前套餐", "Plan")
        case "workbuddy-refresh": language.text("刷新时间", "Refresh")
        case "tokens-today": language.text("今日 Token · 账号", "Today · account")
        case "tokens-yesterday": language.text("昨日 Token · 账号", "Yesterday · account")
        case "credits": language.text("可用额度", "Available credits")
        case "reset": localizedResetLabel(metric.label)
        case "tokens-lifetime": language.text("Token · 累计", "Tokens · all-time")
        case "peak-day": language.text("单日峰值", "Peak day")
        case "longest-task": language.text("最长任务", "Longest task")
        default: metric.label
        }
    }

    private func localizedStatValue(_ metric: UsageStatMetric) -> String {
        if metric.value == "unlimited" { return language.text("无限", "Unlimited") }
        if metric.value == "available" { return language.text("可用", "Available") }
        if metric.value == "unavailable" { return language.text("不可用", "Unavailable") }
        if metric.value == "none" { return language.text("无", "None") }
        if metric.id == "credits" { return Self.formattedCodexCredits(metric.value) }
        if metric.id == "longest-task" {
            guard language == .chinese else { return metric.value }
            return metric.value.replacingOccurrences(of: "h", with: "小时")
                .replacingOccurrences(of: "m", with: "分")
        }
        guard metric.id == "reset", language == .english else { return metric.value }
        if metric.value == "关注中" { return "Watching" }
        if metric.value.hasSuffix(" 天") {
            return metric.value.replacingOccurrences(of: " 天", with: " days")
        }
        return metric.value
            .replacingOccurrences(of: "天", with: "d ")
            .replacingOccurrences(of: "小时", with: "h ")
            .replacingOccurrences(of: "分", with: "m")
            .trimmingCharacters(in: .whitespaces)
    }

    static func formattedCodexCredits(_ value: String) -> String {
        guard let number = Double(value) else { return value }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), number)
    }

    private func localizedStatSubtitle(_ metric: UsageStatMetric) -> String? {
        guard let subtitle = metric.subtitle else { return nil }
        if subtitle == "expires" { return language.text("到期时间", "Expires at this time") }
        guard language == .english else { return subtitle }
        if subtitle == "点击查看详情" { return "Click for details" }
        if subtitle.hasPrefix("平均 "), subtitle.hasSuffix(" 天一轮") {
            let value = subtitle.dropFirst(3).dropLast(4)
            return "Avg. \(value) days between resets"
        }
        return subtitle
            .replacingOccurrences(of: "5 小时窗口", with: "5-hour window")
            .replacingOccurrences(of: "每日窗口", with: "Daily window")
            .replacingOccurrences(of: "7 天窗口", with: "7-day window")
            .replacingOccurrences(of: "每月窗口", with: "Monthly window")
            .replacingOccurrences(of: "每年窗口", with: "Annual window")
            .replacingOccurrences(of: "小时窗口", with: "-hour window")
            .replacingOccurrences(of: "天窗口", with: "-day window")
            .replacingOccurrences(of: "分钟窗口", with: "-minute window")
    }

    private func localizedResetLabel(_ label: String) -> String {
        switch label {
        case "重置": language.text("重置", "Reset")
        case "即将重置": language.text("即将重置", "Reset soon")
        case "Tibo 信号", "Tibo 预告": language.text("Tibo 信号", "Tibo signal")
        case "距上次重置": language.text("距上次重置", "Since last reset")
        default: label
        }
    }

    private func localizedTitle(_ title: String) -> String {
        switch title {
        case "last 7 days", "近 7 天": language.text("近 7 天", "Last 7 days")
        case "last 7 days · local", "近 7 天 · 本地":
            language.text("近 7 天 · 本地", "Last 7 days · local")
        case "last 7 days · account", "近 7 天 · 账号":
            language.text("近 7 天 · 账号", "Last 7 days · account")
        case "last 7 days · plan usage", "近 7 天 · 套餐用量":
            language.text("近 7 天 · 套餐用量", "Last 7 days · plan usage")
        case "last 7 days · spend", "近 7 天 · 消费":
            language.text("近 7 天 · 消费", "Last 7 days · spend")
        case "last 7 days · local credits", "近 7 天 · 本机消耗":
            language.text("近 7 天 · 本机消耗", "Last 7 days · local usage")
        case "active sessions", "活跃会话": language.text("活跃会话", "Active sessions")
        case "all-time · top projects", "累计 · 高频项目":
            language.text("累计 · 高频项目", "All-time · top projects")
        case "recent tasks", "近期任务": language.text("近期任务", "Recent tasks")
        default: title
        }
    }

    private func localizedStatus(_ message: String) -> String {
        if message.contains(" · ") {
            return message.components(separatedBy: " · ").map(localizedStatus).joined(separator: " · ")
        }
        return switch message {
        case "Spend limit reached", "已达消费上限":
            language.text("已达消费上限", "Spend limit reached")
        case "Account usage requires ChatGPT sign-in", "需登录 ChatGPT 才能查看账号用量":
            language.text("需登录 ChatGPT 才能查看账号用量",
                          "Sign in to ChatGPT to view account usage")
        case "未找到 DeepSeek 配置": language.text("未找到 DeepSeek 配置", "DeepSeek configuration not found")
        case "DeepSeek 配置格式无效": language.text("DeepSeek 配置格式无效", "DeepSeek configuration is invalid")
        case "未找到可用 DeepSeek 配置":
            language.text("未找到可用 DeepSeek 配置", "No active DeepSeek configuration found")
        case "DeepSeek API Key 无效": language.text("DeepSeek API Key 无效", "DeepSeek API key is invalid")
        case "DeepSeek 余额不足": language.text("DeepSeek 余额不足", "DeepSeek balance is insufficient")
        case "DeepSeek 请求过于频繁": language.text("DeepSeek 请求过于频繁", "DeepSeek is rate limited")
        case "DeepSeek 服务暂不可用": language.text("DeepSeek 服务暂不可用", "DeepSeek service is unavailable")
        case "DeepSeek 返回格式无效": language.text("DeepSeek 返回格式无效", "DeepSeek response is invalid")
        case "无法连接 DeepSeek": language.text("无法连接 DeepSeek", "Unable to connect to DeepSeek")
        case "未找到 WorkBuddy 登录信息":
            language.text("未找到 WorkBuddy 登录信息", "WorkBuddy sign-in information not found")
        case "WorkBuddy 登录信息无效":
            language.text("WorkBuddy 登录信息无效", "WorkBuddy sign-in information is invalid")
        case "WorkBuddy 登录已过期，请打开 WorkBuddy":
            language.text("WorkBuddy 登录已过期，请打开 WorkBuddy", "WorkBuddy sign-in expired; open WorkBuddy")
        case "WorkBuddy 登录已失效，请打开 WorkBuddy":
            language.text("WorkBuddy 登录已失效，请打开 WorkBuddy", "WorkBuddy sign-in expired; open WorkBuddy")
        case "WorkBuddy 请求过于频繁": language.text("WorkBuddy 请求过于频繁", "WorkBuddy is rate limited")
        case "WorkBuddy 服务暂不可用": language.text("WorkBuddy 服务暂不可用", "WorkBuddy service is unavailable")
        case "WorkBuddy 用量返回格式无效":
            language.text("WorkBuddy 用量返回格式无效", "WorkBuddy usage response is invalid")
        case "无法连接 WorkBuddy": language.text("无法连接 WorkBuddy", "Unable to connect to WorkBuddy")
        case "无法读取 WorkBuddy 近期任务":
            language.text("无法读取 WorkBuddy 近期任务", "Unable to read WorkBuddy recent tasks")
        case "无法读取 WorkBuddy 本机积分记录":
            language.text("无法读取 WorkBuddy 本机积分记录", "Unable to read local WorkBuddy credit records")
        case "未找到 WorkBuddy 数据": language.text("未找到 WorkBuddy 数据", "WorkBuddy data not found")
        case "无法读取 DeepSeek 用量 CSV": language.text("无法读取 DeepSeek 用量 CSV", "Unable to read DeepSeek usage CSV")
        case "DeepSeek 用量 CSV 格式无效": language.text("DeepSeek 用量 CSV 格式无效", "DeepSeek usage CSV is invalid")
        case "DeepSeek 用量 CSV 缺少日期列": language.text("DeepSeek 用量 CSV 缺少日期列", "DeepSeek usage CSV has no date column")
        case "DeepSeek 用量 CSV 缺少金额列": language.text("DeepSeek 用量 CSV 缺少金额列", "DeepSeek usage CSV has no amount column")
        case "DeepSeek 用量 CSV 没有可用消费记录": language.text("DeepSeek 用量 CSV 没有可用消费记录", "DeepSeek usage CSV has no usable spend rows")
        case "DeepSeek 用量 CSV 包含多种币种": language.text("DeepSeek 用量 CSV 包含多种币种", "DeepSeek usage CSV contains multiple currencies")
        case "未在导出目录中找到 cost CSV": language.text("未在“下载”中找到 DeepSeek cost CSV", "No DeepSeek cost CSV found in Downloads")
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
