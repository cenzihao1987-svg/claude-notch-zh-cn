import SwiftUI

/// Approved bottom warning: intrinsic height, details beside the IP, actions bottom-aligned.
struct NetworkWarningView: View {
    let service: EnvironmentGuardService
    let language: AppLanguage
    let animate: Bool
    let measuredHeight: (CGFloat) -> Void
    var detailsVisibilityChanged: (Bool) -> Void = { _ in }
    @State private var showsDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let orange = Color(red: 0.89, green: 0.58, blue: 0.39)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !animate)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        GuardIcon(.shieldAlert, size: 16)
                            .frame(width: 18, height: 18)
                            .overlay {
                                if !reduceMotion {
                                    Circle().stroke(orange, lineWidth: 1)
                                        .scaleEffect(0.8 + phase * 0.8)
                                        .opacity(max(0, 0.35 * (1 - phase * 1.5)))
                                        .allowsHitTesting(false)
                                }
                            }
                        Text(service.connectionMonitor.visibleIssues.isEmpty ? service.snapshot.networkBehavior.title(language) : language.text("Claude 网络预警", "Claude network warning"))
                            .font(.system(size: 12, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }.foregroundStyle(orange)
                    Text(service.connectionMonitor.visibleIssues.map { $0.message(language) }.joined(separator: "\n")
                         + (service.hasGeographicWarning ? (service.connectionMonitor.visibleIssues.isEmpty ? "" : "\n") + service.snapshot.networkBehavior.description(language) : ""))
                        .font(.system(size: 10.5)).lineSpacing(2)
                        .foregroundStyle(Color(red: 0.82, green: 0.77, blue: 0.74))
                        .fixedSize(horizontal: false, vertical: true)
                    if let change = service.exitAlert {
                        HStack(spacing: 4) {
                            Text(verbatim: "\(change.previous.ip) (\(change.previous.country)) → \(change.current.ip) (\(change.current.country))")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Color(red: 0.66, green: 0.58, blue: 0.52))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Button { showsDetails.toggle() } label: {
                                GuardIcon(.circleQuestion, size: 13).frame(width: 22, height: 22)
                            }
                                .buttonStyle(.plain).foregroundStyle(orange)
                                .help(language.text("核验详情", "Verification details"))
                                .accessibilityLabel(language.text("核验详情", "Verification details"))
                                .popover(isPresented: $showsDetails, arrowEdge: .top) {
                                    NetworkWarningDetails(service: service, language: language)
                                }
                        }.padding(.top, 2)
                    }
                    ForEach(service.connectionMonitor.visibleIssues.filter { $0.change != nil }) { issue in
                        if let change = issue.change, change != service.exitAlert {
                            Text(verbatim: "\(change.previous.ip) → \(change.current.ip)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    if !service.connectionMonitor.visibleIssues.isEmpty, let checked = service.connectionMonitor.checkedAt {
                        Text(language.text("检测时间：", "Checked: ") + checked.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7) {
                    Button(language.text("忽略", "Ignore")) { service.ignoreNetworkRisk() }
                        .buttonStyle(NetworkWarningButtonStyle(primary: false))
                    Button {
                        Task { await service.closeClaudeForNetworkRisk(language: language) }
                    } label: {
                        Text(service.isClosingClaude ? language.text("正在关闭…", "Closing…") : language.text("关闭", "Close"))
                    }
                    .buttonStyle(NetworkWarningButtonStyle(primary: true))
                    .disabled(service.isClosingClaude || service.snapshot.client?.pid == nil)
                    .help(language.text("关闭 Claude", "Quit Claude"))
                }.fixedSize()
            }
            .padding(10)
            .background(Color(red: 0.118, green: 0.075, blue: 0.051), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(orange.opacity(reduceMotion ? 0.6 : 0.2 + (1 - cos(phase * .pi * 2)) * 0.225), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { measuredHeight(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in measuredHeight(height) }
            }
        }
        .overlay(alignment: .topTrailing) {
          HStack(spacing: 2) {
            Button { GuardVPNToolOpener.open(language: language) } label: {
                GuardIcon(.globe, size: 13).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain).foregroundStyle(orange.opacity(0.85))
            .help(language.text("打开网络工具", "Open VPN tool"))
            .accessibilityLabel(language.text("网络工具", "VPN tool"))
            .disabled(service.isDesignPreview)
            Button {
                showsDetails = false
                NetworkHistoryWindow.present(service: service, language: language)
            } label: { GuardIcon(.clock, size: 13).frame(width: 22, height: 22) }
                .buttonStyle(.plain).foregroundStyle(orange.opacity(0.85))
                .help(language.text("历史日志", "History log"))
                .accessibilityLabel(language.text("历史日志", "History log"))
          }.padding(8)
        }
        .onChange(of: showsDetails) { _, visible in detailsVisibilityChanged(visible) }
        .onChange(of: animate) { _, expanded in if !expanded { showsDetails = false } }
        .onChange(of: service.snapshot.networkBehavior.identifier) { _, _ in showsDetails = false }
        .onDisappear { detailsVisibilityChanged(false) }
        .accessibilityElement(children: .contain)
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
