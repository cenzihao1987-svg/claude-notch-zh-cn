import AppKit
import SwiftUI

/// Bottom risk banner: one actionable row per problem, pending → checking → resolved, then an
/// all-clear. Hovering a row reveals an × that ignores only that row (risk history is kept).
struct NetworkWarningView: View {
    let service: EnvironmentGuardService
    let language: AppLanguage
    let animate: Bool
    let measuredHeight: (CGFloat) -> Void
    var detailsVisibilityChanged: (Bool) -> Void = { _ in }
    /// Visual checks only: starts with this row's × visible.
    var initialHoveredRow: String? = nil
    @State private var detailsRow: String?
    @State private var hoveredRow: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let orange = Color(red: 0.89, green: 0.58, blue: 0.39)
    private let sage = Color(red: 0.659, green: 0.761, blue: 0.639)
    private var banner: GuardRiskBannerState { service.riskBanner }
    private var allClear: Bool { banner.allClearAt != nil }

    /// Only the breathing border and the icon ripple animate; rows re-render on state changes.
    private var animationPaused: Bool { reduceMotion || !animate || allClear }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if allClear {
                Text(allClearSummary)
                    .font(.system(size: 10.5)).lineSpacing(2)
                    .foregroundStyle(Color(red: 0.749, green: 0.816, blue: 0.733))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            } else {
                VStack(spacing: 5) {
                    ForEach(banner.rows) { row in rowView(row) }
                }.padding(.top, 7)
                if banner.hasNetworkRows { footer.padding(.top, 8) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(allClear ? Color(red: 0.071, green: 0.102, blue: 0.071) : Color(red: 0.118, green: 0.075, blue: 0.051),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: animationPaused)) { context in
                RoundedRectangle(cornerRadius: 10)
                    .stroke(allClear ? sage.opacity(0.45)
                            : orange.opacity(reduceMotion ? 0.6 : 0.2 + (1 - cos(Self.phase(context.date) * .pi * 2)) * 0.225), lineWidth: 1)
            }.allowsHitTesting(false)
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { measuredHeight(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in measuredHeight(height) }
            }
        }
        .overlay(alignment: .topTrailing) {
            if banner.hasNetworkRows && !allClear { tools }
        }
        .onChange(of: detailsRow) { _, row in detailsVisibilityChanged(row != nil) }
        .onChange(of: animate) { _, expanded in if !expanded { detailsRow = nil; hoveredRow = nil } }
        .onChange(of: service.snapshot.networkBehavior.identifier) { _, _ in detailsRow = nil }
        .onDisappear { detailsVisibilityChanged(false) }
        .onAppear { if let initialHoveredRow { hoveredRow = initialHoveredRow } }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: banner)
        .accessibilityElement(children: .contain)
    }

    private static func phase(_ date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
    }

    private var header: some View {
        HStack(spacing: 7) {
            GuardIcon(allClear ? .shieldCheck : .shieldAlert, size: 16)
                .frame(width: 18, height: 18)
                .overlay {
                    if !reduceMotion && !allClear {
                        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: animationPaused)) { context in
                            let phase = Self.phase(context.date)
                            Circle().stroke(orange, lineWidth: 1)
                                .scaleEffect(0.8 + phase * 0.8)
                                .opacity(max(0, 0.35 * (1 - phase * 1.5)))
                        }.allowsHitTesting(false)
                    }
                }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(allClear ? sage : orange)
        .frame(minHeight: 22, alignment: .leading)
    }

    private var title: String {
        if allClear { return language.text("已全部处理，可以继续使用 Claude", "All handled — Claude is ready to use") }
        let count = banner.openCount
        return banner.showsResolvedRows
            ? language.text("Claude 风险提醒 · 还剩 \(count) 项", "Claude risk alerts · \(count) left")
            : language.text("Claude 风险提醒 · \(count) 项待处理", "Claude risk alerts · \(count) to handle")
    }

    private var tools: some View {
        HStack(spacing: 2) {
            Button { GuardVPNToolOpener.open(language: language) } label: {
                GuardIcon(.globe, size: 13).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain).foregroundStyle(orange.opacity(0.85))
            .help(language.text("打开网络工具", "Open VPN tool"))
            .accessibilityLabel(language.text("网络工具", "VPN tool"))
            .disabled(service.isDesignPreview)
            Button {
                detailsRow = nil
                NetworkHistoryWindow.present(service: service, language: language)
            } label: { GuardIcon(.clock, size: 13).frame(width: 22, height: 22) }
                .buttonStyle(.plain).foregroundStyle(orange.opacity(0.85))
                .help(language.text("历史日志", "History log"))
                .accessibilityLabel(language.text("历史日志", "History log"))
        }.padding(8)
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if let checked = service.connectionMonitor.checkedAt ?? service.snapshot.network?.fetchedAt {
                Text(language.text("检测时间 ", "Checked ") + checked.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 9)).foregroundStyle(Color(red: 0.92, green: 0.92, blue: 0.96).opacity(0.5))
            }
            Spacer(minLength: 0)
            Button {
                Task { await service.closeClaudeForNetworkRisk(language: language) }
            } label: {
                Text(service.isClosingClaude ? language.text("正在关闭…", "Closing…") : language.text("关闭 Claude", "Quit Claude"))
            }
            .buttonStyle(NetworkWarningButtonStyle(primary: true))
            .disabled(service.isClosingClaude || service.snapshot.client?.pid == nil)
            .fixedSize()
        }
    }

    // MARK: rows

    @ViewBuilder private func rowView(_ row: GuardRiskBannerState.Row) -> some View {
        let resolved = !row.isOpen
        HStack(spacing: 9) {
            statusIcon(row)
            VStack(alignment: .leading, spacing: 1) {
                Text(resolved ? resolvedText(row.item) : message(row.item))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(resolved ? sage : Color(red: 0.933, green: 0.890, blue: 0.863))
                    .fixedSize(horizontal: false, vertical: true)
                if !resolved, let sub = subtitle(row) {
                    Text(verbatim: sub.text)
                        .font(sub.mono ? .system(size: 9.5, design: .monospaced) : .system(size: 9))
                        .foregroundStyle(sub.mono ? Color(red: 0.659, green: 0.580, blue: 0.522)
                                         : Color(red: 0.92, green: 0.92, blue: 0.96).opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if case .resolved(let at) = row.phase {
                Text(language.text("已核验 ", "Verified ") + at.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 9)).foregroundStyle(Color(red: 0.92, green: 0.92, blue: 0.96).opacity(0.5))
            } else if case .pending = row.phase {
                actionButton(row.item)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 9)
        .background(rowBackground(row), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .topLeading) {
            if hoveredRow == row.id && row.isOpen {
                Button { service.ignoreRiskItem(row.id) } label: {
                    GuardIcon(.close, size: 9)
                        .foregroundStyle(Color(red: 0.91, green: 0.79, blue: 0.71))
                        .frame(width: 17, height: 17)
                        .background(Circle().fill(Color(red: 0.227, green: 0.165, blue: 0.125)))
                        .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: -6, y: -6)
                .help(language.text("忽略此项", "Ignore this item"))
                .accessibilityLabel(language.text("忽略此项", "Ignore this item"))
                .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredRow = row.id } else if hoveredRow == row.id { hoveredRow = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(language.text("忽略此项", "Ignore this item"))) { service.ignoreRiskItem(row.id) }
    }

    private func rowBackground(_ row: GuardRiskBannerState.Row) -> Color {
        if !row.isOpen { return sage.opacity(0.06) }
        return Color.white.opacity(hoveredRow == row.id ? 0.065 : 0.035)
    }

    @ViewBuilder private func statusIcon(_ row: GuardRiskBannerState.Row) -> some View {
        Group {
            switch row.phase {
            case .pending: GuardIcon(.circleAlert, size: 14).foregroundStyle(orange)
            case .checking:
                if reduceMotion { GuardIcon(.loader, size: 14).foregroundStyle(orange) }
                else {
                    TimelineView(.animation) { context in
                        GuardIcon(.loader, size: 14).foregroundStyle(orange)
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360))
                    }
                }
            case .resolved: GuardIcon(.circleCheck, size: 14).foregroundStyle(sage)
            }
        }.frame(width: 16, height: 16)
    }

    @ViewBuilder private func actionButton(_ item: GuardRiskItem) -> some View {
        Button { perform(item) } label: {
            HStack(spacing: 3) {
                Text(actionTitle(item))
                if item.action == .openClash { GuardIcon(.arrowUpRight, size: 10) }
            }
        }
        .buttonStyle(RiskRowButtonStyle())
        .disabled(item.action == .relaunch && (service.isLaunching || service.isClosingClaude))
        .fixedSize()
        .popover(isPresented: Binding(get: { detailsRow == item.id }, set: { if !$0 { detailsRow = nil } }), arrowEdge: .top) {
            NetworkWarningDetails(service: service, language: language)
        }
    }

    private func perform(_ item: GuardRiskItem) {
        switch item.action {
        case .openClash: service.openClashForRisk(item.id, language: language)
        case .recheck: service.recheckRisk(item.id)
        case .confirmExit: service.confirmExitForRisk()
        case .details: detailsRow = detailsRow == item.id ? nil : item.id
        case .relaunch:
            guard case .protection(let state) = item.kind, GuardRestartConfirmation.ask(state: state, language: language) else { return }
            Task {
                let launched = await service.relaunchWithProtection(itemID: item.id)
                if !launched, service.operationFailed { GuardRestartConfirmation.showFailure(service: service, language: language) }
            }
        }
    }

    // MARK: copy

    private func message(_ item: GuardRiskItem) -> String {
        switch item.kind {
        case .protection(.profileChanged): language.text("专属配置已变化，重启后生效", "Profile changed; restart to apply")
        case .protection(.profileOff): language.text("Claude 防护未开启", "Claude protection is off")
        case .protection: language.text("Claude 未从刘海启动，防护未生效", "Claude wasn't opened from the notch; protection is off")
        case .clash(.notRunning): language.text("Clash Verge 未运行", "Clash Verge is not running")
        case .clash(.unknown): language.text("Clash Verge 模式无法核验", "Clash Verge mode unverified")
        case .clash(let state): language.text("Clash Verge 为\(state.label(language))", "Clash Verge: \(state.label(language))")
        case .exitUnknown: language.text("当前出口无法确认", "The current exit could not be verified")
        case .ipChanged: language.text("公网出口 IP 已变化", "The public exit IP changed")
        case .geography: service.snapshot.networkBehavior.title(language)
        }
    }

    private func subtitle(_ row: GuardRiskBannerState.Row) -> (text: String, mono: Bool)? {
        if case .checking = row.phase {
            switch row.item.action {
            case .openClash: return (language.text("已打开 Clash Verge · 切到「全局」后这里会自动更新", "Clash Verge opened · this updates after you switch to Global"), false)
            case .relaunch: return (language.text("正在以防护重启 Claude…", "Restarting Claude with protection…"), false)
            default: return (language.text("正在重新检查…", "Checking…"), false)
            }
        }
        let system = service.systemEnvironment
        switch row.item.kind {
        case .protection(.notFromNotch(let instances)) where instances > 1:
            return (language.text("检测到 \(instances) 个 Claude 实例", "\(instances) Claude instances are running"), false)
        case .protection(.profileChanged):
            let profile = service.profile
            return (language.text("重启后使用：", "After restart: ") + GuardDisplayNames.environment(language: profile.languageCode,
                locale: profile.localeIdentifier, timeZone: profile.timeZoneIdentifier, in: language), false)
        case .protection:
            return (language.text("正在使用系统配置：", "Using system settings: ") + GuardDisplayNames.environment(language: system.languageCode,
                locale: system.localeIdentifier, timeZone: system.timeZoneIdentifier, in: language), false)
        case .clash(.unknown): return (language.text("本机内核没有响应", "The local core did not respond"), false)
        case .clash: return (language.text("Claude 的请求可能不走代理", "Claude's requests may bypass the proxy"), false)
        case .exitUnknown: return (language.text("出口查询失败，保留上次结果", "Lookup failed; the last result is kept"), false)
        case .ipChanged(let change):
            return ("\(change.previous.ip) → \(change.current.ip) · " + GuardDisplayNames.country(change.current.country, language: language), true)
        case .geography:
            if let change = service.snapshot.networkBehavior.change {
                return ("\(change.previous.ip) (\(change.previous.country)) → \(change.current.ip) (\(change.current.country))", true)
            }
            return (service.snapshot.networkBehavior.description(language), false)
        }
    }

    private func actionTitle(_ item: GuardRiskItem) -> String {
        switch item.kind {
        case .protection(.profileOff): language.text("开启防护并重启", "Turn on & restart")
        case .protection: language.text("以防护重启", "Restart protected")
        case .clash(.notRunning): language.text("启动 Clash Verge", "Open Clash Verge")
        case .clash(.unknown), .exitUnknown: language.text("重新检查", "Check again")
        case .clash: language.text("打开 Clash Verge", "Open Clash Verge")
        case .ipChanged: language.text("是我切换的", "It was me")
        case .geography: language.text("查看详情", "Details")
        }
    }

    private func resolvedText(_ item: GuardRiskItem) -> String {
        switch item.kind {
        case .protection: language.text("已以防护启动，专属配置生效", "Restarted with protection")
        case .clash: language.text("Clash Verge 已切到全局模式", "Clash Verge switched to Global")
        case .exitUnknown: language.text("已取得当前出口", "Current exit verified")
        case .ipChanged(let change): language.text("已确认新出口 \(change.current.ip)", "New exit \(change.current.ip) confirmed")
        case .geography: language.text("出口提醒已解除", "Exit warning cleared")
        }
    }

    private var allClearSummary: String {
        banner.resolvedItems.map { item in
            switch item.kind {
            case .protection: language.text("已以防护启动", "Restarted with protection")
            case .clash: language.text("Clash 全局模式已核验", "Clash Global mode verified")
            case .exitUnknown: language.text("当前出口已取得", "Current exit verified")
            case .ipChanged(let change): language.text("出口 \(change.current.ip) 已确认为新基准", "Exit \(change.current.ip) confirmed as the new baseline")
            case .geography: language.text("出口提醒已解除", "Exit warning cleared")
            }
        }.joined(separator: " · ")
    }
}

/// Inline row action: orange text on a 16% orange fill.
private struct RiskRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10))
            .foregroundStyle(Color(red: 0.89, green: 0.58, blue: 0.39))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color(red: 0.89, green: 0.58, blue: 0.39).opacity(configuration.isPressed ? 0.26 : 0.16),
                        in: RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Restart confirmation shared by the banner and the welcome card. Claude quits normally; never forced.
@MainActor
enum GuardRestartConfirmation {
    static func ask(state: GuardProtectionState, language: AppLanguage) -> Bool {
        let alert = NSAlert()
        alert.messageText = state == .profileOff
            ? language.text("开启防护并重启 Claude？", "Turn on protection and restart Claude?")
            : language.text("以防护重启 Claude？", "Restart Claude with protection?")
        alert.informativeText = language.text("Claude 会正常退出，再按专属语言、地区和时区启动；进行中的任务可能中断。",
                                              "Claude quits normally, then starts with your language, region and timezone. Work in progress may be interrupted.")
        alert.addButton(withTitle: language.text("重启", "Restart"))
        alert.addButton(withTitle: language.text("取消", "Cancel"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func showFailure(service: EnvironmentGuardService, language: AppLanguage) {
        let alert = NSAlert()
        alert.messageText = language.text("未能完成启动", "Could not finish the launch")
        alert.informativeText = service.operationMessage?.text(language) ?? ""
        alert.addButton(withTitle: language.text("好", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Context for this warning only; deliberately excludes account/settings and other guard findings.
struct NetworkWarningDetails: View {
    let service: EnvironmentGuardService
    let language: AppLanguage
    private var behavior: GuardNetworkBehavior { service.snapshot.networkBehavior }

    private var evidence: [GuardGeoTransition] {
        guard let change = behavior.change else { return [] }
        let records = (service.networkTracker.history.geographicTransitions ?? []).filter {
            let gap = change.current.observedAt.timeIntervalSince($0.current.observedAt)
            return $0.isExposureQualified && gap >= 0 && gap <= (behavior.kind == .cumulative ? 86400 : 3600)
        }
        switch behavior.kind {
        case .repeated, .roundTrip: return Array(records.filter(\.anomalous).suffix(3))
        case .cumulative: return Array(records.suffix(4))
        case .anomalous, .countryChange: return records.filter { $0.id == change.id }
        default: return []
        }
    }

    private var reason: String {
        switch behavior.kind {
        case .repeated: language.text("短时间内，出口在相距较远的多个地区连续跳转。", "The exit switched rapidly across distant regions.")
        case .roundTrip: language.text("出口在短时间内跨区后又返回原地区，形成往返跳转。", "The exit switched to a distant region and quickly returned.")
        case .anomalous: language.text("前后两次出口位于相距较远的地区，切换间隔不足 2 小时。", "Consecutive exits were in distant regions less than two hours apart.")
        case .familyMismatch: language.text("最近采样的 IPv4 和 IPv6 出口位于不同国家／地区。", "Recent IPv4 and IPv6 samples point to different countries or regions.")
        case .unverified: language.text("定位来源尚未取得一致结果，暂时不能确认新出口的地区。", "Location sources have not agreed, so the new exit region is unverified.")
        case .cumulative: language.text("24 小时内累计跨区次数较多，需要检查线路是否自动切换。", "Frequent region changes within 24 hours suggest checking automatic route switching.")
        case .countryChange: language.text("出口国家／地区发生变化，尚未命中远距离异常规则。", "The exit country or region changed without triggering the distant-switch rule.")
        case nil: language.text("当前没有出口异常。", "No current exit warning.")
        }
    }

    private var rule: String {
        switch behavior.kind {
        case .repeated, .roundTrip:
            language.text("Claude 运行期间，1 小时内至少 2 次已核验异常跨区；已完成间隔至少 5 秒复测及双来源国别核验。", "At least two verified abnormal switches within one hour; repeated samples after five seconds and two country sources agree.")
        case .anomalous:
            language.text("Claude 运行期出口在 2 小时内切换到远隔地区；已完成间隔至少 5 秒复测及双来源国别核验。", "Distant regions changed within two hours; repeated samples after five seconds and two country sources agree.")
        case .familyMismatch:
            language.text("IPv4／IPv6 分别跟踪，地区分歧单独提示，不累计成多次跨区。", "Address families are tracked separately; this disagreement does not count as repeated travel.")
        case .unverified:
            language.text("保留上次有效基准，待定位核验后再判断是否异常跨区。", "The last valid baseline is retained until location verification completes.")
        case .cumulative:
            language.text("24 小时跨区至少 4 次；同国换 IP 和城市变化不计入。", "At least four region changes in 24 hours; same-country IP and city changes are excluded.")
        case .countryChange:
            language.text("已完成新出口重复采样；同国换 IP 和城市变化不计分。", "The new exit was sampled repeatedly; same-country IP and city changes add no points.")
        case nil: ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(behavior.title(language)).font(.system(size: 13, weight: .semibold))
            Text(reason).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Divider()
            if evidence.isEmpty, let change = behavior.change {
                exitRow(behavior.kind == .familyMismatch ? family(change.previous) : language.text("上次出口", "Previous"), exit: change.previous)
                exitRow(behavior.kind == .familyMismatch ? family(change.current) : language.text("当前出口", "Current"), exit: change.current)
            } else {
                ForEach(evidence) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(region(item.previous.country) + " → " + region(item.current.country))
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(item.current.observedAt, style: .time).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Text(verbatim: item.previous.ip + " → " + item.current.ip)
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
            Divider()
            Text(rule).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !behavior.locationUnverified {
                Text(language.text("网络行为 \(behavior.points) 分", "Network behavior: \(behavior.points) points")
                     + (behavior.minimumTotal > 0 ? language.text(" · 总风险至少 \(behavior.minimumTotal)", " · total at least \(behavior.minimumTotal)") : ""))
                    .font(.system(size: 11, weight: .medium))
            }
        }.padding(14).frame(width: 350).fixedSize(horizontal: false, vertical: true)
    }

    private func family(_ exit: GuardExit) -> String { exit.ip.contains(":") ? "IPv6" : "IPv4" }
    private func region(_ code: String) -> String { Locale(identifier: language == .chinese ? "zh_CN" : "en_US").localizedString(forRegionCode: code) ?? code }
    private func exitRow(_ title: String, exit: GuardExit) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title + " · " + region(exit.country)).font(.system(size: 11, weight: .medium))
            Text(verbatim: exit.ip).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

private struct NetworkWarningButtonStyle: ButtonStyle {
    var primary: Bool
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: primary ? .semibold : .regular))
            .padding(.horizontal, 11).padding(.vertical, 5)
            .foregroundStyle(primary ? Color(red: 0.14, green: 0.086, blue: 0.05) : Color(red: 0.87, green: 0.70, blue: 0.60))
            .background(primary ? Color(red: 0.89, green: 0.58, blue: 0.39) : Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(primary ? Color.clear : Color(red: 0.47, green: 0.32, blue: 0.23), lineWidth: 1) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}
