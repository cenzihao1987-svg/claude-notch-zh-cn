import AppKit
import SwiftUI

/// V3 layout, recolored to match the user's native Settings panel.
enum GuardVisual {
    static let width: CGFloat = 852
    static let height: CGFloat = 776
    static let titlebarHeight: CGFloat = 43
    static let inset: CGFloat = 21
    static let corner: CGFloat = 13
    static let text = Color.primary
    static let secondary = Color.secondary
    static let muted = Color.secondary.opacity(0.75)
    static let clay = AppPalette.accent
    static let sage = Color(hex: 0xA8C2A3)
    static let amber = clay
    static let line = Color.white.opacity(0.06)
    static let window = AppPalette.window
    static let card = AppPalette.group
    static let field = AppPalette.field

}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

extension GuardSummary {
    var color: Color {
        switch self {
        case .attention: GuardVisual.amber
        case .checking, .unverified: GuardVisual.secondary
        case .clear: .green
        }
    }

    var glyph: GuardGlyph {
        switch self {
        case .attention: .shieldAlert
        case .checking, .unverified: .shieldQuestion
        case .clear: .shieldCheck
        }
    }
}

struct EnvironmentGuardBadge: View {
    let model: AppModel
    let onOpen: () -> Void

    var body: some View {
        let summary = model.environmentGuard.summary
        Button(action: onOpen) {
            HStack(spacing: 4) {
                GuardIcon(summary.glyph, size: 15)
                if case .attention(let count) = summary {
                    Text(count > 9 ? "9+" : "\(count)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
            }
            .foregroundStyle(summary.color)
            .frame(width: 40, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.language.text("Claude 环境：", "Claude environment: ") + summary.text(model.language))
        .accessibilityLabel(model.language.text("打开 Claude 环境", "Open Claude environment"))
        .accessibilityValue(summary.text(model.language))
    }
}

struct EnvironmentGuardView: View {
    let model: AppModel
    var onClose: () -> Void = {}
    var onMinimize: () -> Void = {}
    var onZoom: () -> Void = {}
    var onPreferredHeight: (CGFloat) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showRules = false
    @State private var showVerification = false
    @State private var missingField: String?

    private var service: EnvironmentGuardService { model.environmentGuard }
    private var language: AppLanguage { model.language }
    private var isRunning: Bool { service.snapshot.client?.pid != nil }
    private var regions: [String] {
        Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }.sorted {
            (displayLocale.localizedString(forRegionCode: $0) ?? $0).localizedStandardCompare(displayLocale.localizedString(forRegionCode: $1) ?? $1) == .orderedAscending
        }
    }
    private var resultAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.25) }
    private var displayLocale: Locale { Locale(identifier: language == .chinese ? "zh_CN" : "en_US") }

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        pageHeading.padding(.bottom, 17)
                        systemCard
                        profileCard.padding(.top, 18).id("profile")
                        verification.padding(.top, 14)
                    }.padding(.horizontal, GuardVisual.inset).padding(.top, 20).padding(.bottom, 18)
                }.scrollIndicators(.hidden)
                    .onChange(of: missingField) { _, value in
                        if value != nil { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("profile", anchor: .bottom) } }
                    }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(GuardVisual.text)
        .background(GuardVisual.window)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.2), lineWidth: 1) }
        .frame(width: GuardVisual.width)
        .onAppear { onPreferredHeight(GuardVisual.height) }
    }

    private var titlebar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                trafficLight(Color(hex: 0xF2645D), label: language.text("关闭窗口", "Close window"), action: onClose)
                trafficLight(Color(hex: 0xECC15B), label: language.text("最小化窗口", "Minimize window"), action: onMinimize)
                trafficLight(Color(hex: 0x6CB961), label: language.text("缩放窗口", "Zoom window"), action: onZoom)
            }
            Text(language.text("Claude 环境", "Claude Environment")).font(.system(size: 13, weight: .semibold)).padding(.leading, 24)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(isRunning ? GuardVisual.sage : GuardVisual.muted).frame(width: 5, height: 5)
                Text(service.isLaunching ? language.text("Claude 正在启动", "Claude is launching") : isRunning
                     ? language.text("Claude 正在运行", "Claude is running") : language.text("Claude 未运行", "Claude is stopped"))
            }.font(.system(size: 10)).foregroundStyle(GuardVisual.secondary)
        }.padding(.horizontal, 18).frame(height: GuardVisual.titlebarHeight)
            .background(GuardWindowDragArea())
            .background(GuardVisual.window)
            .overlay(alignment: .bottom) { Rectangle().fill(GuardVisual.line).frame(height: 1) }
    }

    private func trafficLight(_ color: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Circle().fill(color).frame(width: 11, height: 11).contentShape(Circle()) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }

    private var pageHeading: some View {
        HStack(spacing: 9) {
            Text(language.text("规则风险指数", "Rule risk index")).font(.system(size: 16, weight: .semibold))
            Button { showRules.toggle() } label: {
                GuardIcon(.circleQuestion, size: 16).foregroundStyle(GuardVisual.muted).frame(width: 26, height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(language.text("评分规则", "Scoring rules"))
                .popover(isPresented: $showRules) { rules }
            Spacer()
            if service.isDesignPreview {
                Text(language.text("示例数据", "Example data")).font(.system(size: 10)).foregroundStyle(GuardVisual.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 5).background(GuardVisual.field, in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(GuardVisual.line, lineWidth: 1) }
            }
        }.padding(.horizontal, 2).frame(height: 26)
    }

    private var systemCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                GuardIcon(.appWindow, size: 14).foregroundStyle(GuardVisual.muted)
                Text(language.text("当前系统环境", "Current system environment")).font(.system(size: 13, weight: .medium))
                Spacer()
                Button { Task { await service.recheck() } } label: {
                    HStack(spacing: 6) {
                        if service.isRechecking {
                            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        } else { GuardIcon(.refresh, size: 12) }
                        Text(language.text(service.isRechecking ? "检测中…" : "重新检测",
                                           service.isRechecking ? "Checking…" : "Check again"))
                    }.font(.system(size: 10.5)).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(service.isRechecking)
                    .help(checkAge)
            }.foregroundStyle(GuardVisual.secondary).frame(height: 17).padding(.bottom, 13)
            HStack(spacing: 17) {
                HStack(spacing: 12) {
                    gauge(service.currentRisk, caption: "", small: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(riskTitle(service.currentRisk)).contentTransition(.opacity).animation(resultAnimation, value: service.isRechecking).font(.system(size: 15, weight: .semibold)).foregroundStyle(riskColor(service.currentRisk))
                        Text(language.text("当前风险 · 满分 100", "Current risk · out of 100")).font(.system(size: 9.5)).foregroundStyle(GuardVisual.muted)
                    }
                }.frame(width: 177, alignment: .leading)
                Rectangle().fill(GuardVisual.line).frame(width: 1, height: 37)
                HStack(spacing: 20) {
                    systemFact(language.text("应用语言", "App language"), value: languageName(service.systemEnvironment.languageCode, includeCode: false)).frame(maxWidth: .infinity, alignment: .leading)
                    systemFact(language.text("地区格式", "Region format"), value: regionName(service.systemEnvironment.localeIdentifier, includeCode: false)).frame(maxWidth: .infinity, alignment: .leading)
                    systemFact(language.text("系统时区", "System timezone"), value: service.systemEnvironment.timeZoneIdentifier, code: true).frame(width: 235, alignment: .leading)
                }.padding(.leading, 5)
            }.frame(height: 43)
            separator.padding(.top, 13).padding(.bottom, 9)
            breakdown(service.currentRisk, configured: false).font(.system(size: 11))
        }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            .frame(height: 142)
            .background(panelBackground())
    }

    private func systemFact(_ title: String, value: String, code: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(GuardVisual.muted)
            Text(service.isRechecking ? language.text("读取中…", "Reading…") : value.isEmpty ? "—" : value)
                .contentTransition(.opacity).animation(resultAnimation, value: service.isRechecking).font(.system(size: code ? 11.5 : 12))
                .foregroundStyle(GuardVisual.text).lineLimit(1).truncationMode(.middle).help(value)
        }
    }

    private var webFinding: GuardFinding {
        if service.isRechecking {
            return .init(id: "chromium", title: .init("网页层实际值", "Actual page values"),
                         value: .init("正在核验…", "Checking…"), detail: .init("正在更新网页环境读数。", "Updating actual page readings."), state: .pending)
        }
        return GuardWebEvaluator.finding(profile: service.profile, state: service.snapshot.webEnvironment, launchPending: false)
    }
    private func reading(_ field: GuardWebField) -> GuardWebReading {
        if service.isRechecking { return .init(values: [], state: .unknown) }
        return GuardWebEvaluator.reading(field, profile: service.profile, state: service.snapshot.webEnvironment)
    }
    private var webDifferenceCount: Int { GuardWebField.allCases.filter { reading($0).state == .attention }.count }
    private var canApplyWhileRunning: Bool {
        service.profile.enabled && (webDifferenceCount > 0 || service.findings.contains { $0.id == "launch" && $0.actionID == "launch" })
    }
    private var webColor: Color {
        switch webFinding.state {
        case .passed: GuardVisual.sage
        case .attention: GuardVisual.clay
        default: GuardVisual.muted
        }
    }

    private var profileCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(language.text("专属启动环境", "Dedicated launch environment")).font(.system(size: 18, weight: .semibold))
                Spacer()
                Text(language.text("专属配置", "Launch profile")).font(.system(size: 11)).foregroundStyle(GuardVisual.text)
                Toggle("", isOn: Binding(get: { service.profile.enabled }, set: { enabled in setProfileEnabled(enabled) }))
                    .labelsHidden().toggleStyle(GuardSwitchStyle()).disabled(service.isLaunching || service.isRechecking)
                    .accessibilityLabel(language.text("专属配置", "Launch profile"))
            }.frame(height: 22)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .center, spacing: 22) {
                    gauge(service.configuredRisk, caption: language.text("配置预估风险", "Estimated profile risk"))
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(GuardVisual.clay).frame(width: 4, height: 4).padding(.top, 6)
                        Text(language.text("仅用于此处启动的 Claude\n不修改系统设置", "Only for Claude launched here\nSystem settings stay unchanged"))
                            .font(.system(size: 9)).foregroundStyle(GuardVisual.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 6)
                }.padding(.top, 3).frame(width: 132)
                profileDetail.frame(maxWidth: .infinity)
            }.padding(.top, 21).opacity(service.profile.enabled ? 1 : 0.37)
            Spacer(minLength: 0)
        }.padding(.horizontal, 20).padding(.vertical, 19).frame(height: 408)
            .background(panelBackground())
    }

    private var profileDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(riskTitle(service.configuredRisk)).contentTransition(.opacity).animation(resultAnimation, value: service.isRechecking).font(.system(size: 26, weight: .semibold)).foregroundStyle(riskColor(service.configuredRisk))
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    GuardIcon(webFinding.state == .passed ? .shieldCheck : webFinding.state == .attention ? .circleAlert : .clock, size: 13)
                    Text(webFinding.value.text(language)).contentTransition(.opacity).animation(resultAnimation, value: service.isRechecking)
                }.font(.system(size: 10)).foregroundStyle(webColor).help(webFinding.detail.text(language))
            }.frame(height: 32)
            breakdown(service.configuredRisk, configured: true).font(.system(size: 11.5)).padding(.top, 8)
            comparison.padding(.top, 19)
            HStack(spacing: 10) {
                Text(webReadingSummary).foregroundStyle(webColor).contentTransition(.opacity).animation(resultAnimation, value: service.isRechecking)
                Spacer(minLength: 0)
                TimelineView(.periodic(from: .now, by: 10)) { _ in
                    Text(webReadingAge).foregroundStyle(GuardVisual.secondary).contentTransition(.opacity).animation(resultAnimation, value: service.isRechecking)
                }
            }.font(.system(size: 10)).lineLimit(1).frame(height: 14).padding(.horizontal, 2).padding(.top, 9).padding(.bottom, 15)
            Button(action: launch) { Text(launchTitle).frame(maxWidth: .infinity) }
                .buttonStyle(GuardActionStyle(primary: true, height: 39))
                .disabled(service.isLaunching || service.isRechecking || (isRunning && !canApplyWhileRunning))
        }
    }

    private var comparison: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 93, height: 1)
                Text(language.text("配置值", "Configured value")).frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text(language.text("网页层实际值", "Actual page value"))
                    Spacer()
                    Circle().fill(webFinding.state == .passed ? GuardVisual.sage : GuardVisual.muted).frame(width: 4, height: 4).padding(.trailing, 4)
                }.frame(maxWidth: .infinity)
            }.font(.system(size: 11)).foregroundStyle(GuardVisual.secondary).padding(.horizontal, 10).frame(height: 23, alignment: .top)
            VStack(spacing: 0) {
                comparisonRow(.languages, title: language.text("应用语言", "App language"), field: .language) {
                    dropdown(title: language.text("应用语言", "App language"), value: languageName(service.profile.languageCode), key: "language",
                             options: GuardProfile.languages.map { ($0, languageName($0)) }) { code in
                        var value = service.profile
                        value.languageCode = code
                        if let region = value.countryCode {
                            value.localeIdentifier = "\(Locale(identifier: code).language.languageCode?.identifier ?? "en")_\(region)"
                        }
                        service.updateProfile(value)
                    }
                }
                separator
                comparisonRow(.globe, title: language.text("地区格式", "Region format"), field: .region) {
                    dropdown(title: language.text("地区格式", "Region format"), value: regionName(service.profile.localeIdentifier), key: "region",
                             options: regions.map { ($0, displayLocale.localizedString(forRegionCode: $0) ?? $0) }) { code in
                        var value = service.profile; value.selectRegion(code); service.updateProfile(value)
                    }
                }
                separator
                comparisonRow(.clock, title: language.text("进程时区", "Process timezone"), field: .timezone) {
                    dropdown(title: language.text("进程时区", "Process timezone"), value: service.profile.timeZoneIdentifier.isEmpty
                             ? language.text("选择时区", "Choose timezone") : service.profile.timeZoneIdentifier, key: "timezone",
                             options: TimeZone.knownTimeZoneIdentifiers.map { ($0, $0) }) { zone in
                        var value = service.profile; value.selectTimeZone(zone); service.updateProfile(value)
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(GuardVisual.line, lineWidth: 1) }
        }
    }

    private func comparisonRow<Content: View>(_ icon: GuardGlyph, title: String, field: GuardWebField, @ViewBuilder content: () -> Content) -> some View {
        let actual = reading(field)
        return HStack(spacing: 12) {
            HStack(spacing: 9) {
                GuardIcon(icon, size: 17).foregroundStyle(GuardVisual.text)
                Text(title).font(.system(size: 13))
            }.frame(width: 93, alignment: .leading)
            content().frame(maxWidth: .infinity).disabled(!service.profile.enabled || service.isLaunching || service.isRechecking)
            HStack(spacing: 8) {
                Text(service.isRechecking ? language.text("读取中…", "Reading…") : actual.text)
                    .contentTransition(.opacity).animation(resultAnimation, value: service.isRechecking).font(.system(size: 12))
                    .foregroundStyle(service.isRechecking ? GuardVisual.secondary : actual.state == .attention ? GuardVisual.clay : GuardVisual.text)
                    .lineLimit(2).truncationMode(.middle).help(actual.text).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                GuardIcon(actual.state == .passed ? .check : actual.state == .attention ? .circleAlert : .clock, size: 12)
                    .foregroundStyle(actual.state == .passed ? GuardVisual.sage : actual.state == .attention ? GuardVisual.clay : GuardVisual.muted)
                    .frame(width: 18, height: 18)
                    .background(actual.state == .passed ? GuardVisual.sage.opacity(0.13) : actual.state == .attention ? GuardVisual.clay.opacity(0.13) : GuardVisual.muted.opacity(0.06), in: Circle())
                    .opacity(service.isRechecking ? 0 : 1)
                    .animation(resultAnimation, value: service.isRechecking)
                    .accessibilityLabel(actual.state == .passed ? language.text("与配置一致", "Matches profile") : actual.state == .attention
                                        ? language.text("与配置不一致", "Differs from profile") : language.text("尚未核验", "Unverified"))
            }.padding(.leading, 3).frame(maxWidth: .infinity)
        }.padding(.horizontal, 10).frame(height: 47)
    }

    private var webReadingSummary: String {
        if service.isRechecking { return language.text("正在更新网页层实际值…", "Updating actual page values…") }
        if !service.profile.enabled { return language.text("专属配置已关闭", "Launch profile is off") }
        if webDifferenceCount > 0 { return language.text("\(webDifferenceCount) 项实际值与配置不同", "\(webDifferenceCount) values differ from profile") }
        if webFinding.state == .passed { return language.text("3 项实际值与配置一致", "3 values match the profile") }
        return webFinding.value.text(language)
    }
    private var webReadingAge: String {
        if service.isRechecking { return "" }
        guard case .observed(let report) = service.snapshot.webEnvironment else { return "—" }
        let date = Date(timeIntervalSince1970: report.capturedAt / 1000)
        if date.timeIntervalSinceNow > -15 { return language.text("刚刚采样", "Just sampled") }
        return Fmt.ago(date, language: language) + language.text("前采样", " ago")
    }

    private func gauge(_ risk: GuardRiskAssessment, caption: String, small: Bool = false) -> some View {
        GuardRiskGauge(total: risk.total, caption: caption.isEmpty ? language.text("当前风险", "Current risk") : caption,
                       compact: small, checking: service.isRechecking,
                       checkingLabel: language.text("检测中", "Checking"), unknownLabel: language.text("未检测", "Not checked"))
    }

    private func riskTitle(_ risk: GuardRiskAssessment) -> String {
        service.isRechecking ? language.text("检测中…", "Checking…") : risk.level(language)
    }
    private func riskColor(_ risk: GuardRiskAssessment) -> Color {
        service.isRechecking ? GuardVisual.secondary : (risk.total ?? 0) >= 50 ? GuardVisual.clay : GuardVisual.text
    }

    private var networkLocation: String {
        if service.isRechecking { return language.text("检测中…", "Checking…") }
        guard service.networkChecksEnabled else { return language.text("检测已关闭", "Checks off") }
        guard service.snapshot.networkIsFresh(at: .now), let network = service.snapshot.network else { return "—" }
        let country = displayLocale.localizedString(forRegionCode: network.countryCode) ?? network.countryCode
        let place = [network.city, network.subdivision].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        return place.map { country + " · " + $0 } ?? country
    }
    private func breakdown(_ risk: GuardRiskAssessment, configured: Bool) -> some View {
        let local = service.isRechecking ? "—" : risk.local.map(String.init) ?? "—"
        let client = service.isRechecking ? "—" : risk.client.map(String.init) ?? "—"
        let value = language.text("本地特征 \(local)  ·  IP 所在地：\(networkLocation)  ·  客户端来源 \(client)",
                                  "Local \(local)  ·  IP location: \(networkLocation)  ·  Client source \(client)")
        return Text(!service.isRechecking && risk.network == 40 ? value + language.text("  ·  网络 40", "  ·  Network 40") : value)
            .foregroundStyle(GuardVisual.secondary)
            .contentTransition(.opacity).animation(resultAnimation, value: service.isRechecking)
            .lineLimit(1).minimumScaleFactor(0.8).frame(height: 19, alignment: .leading).help(value)
    }

    private var verification: some View {
        Button { showVerification.toggle() } label: {
            HStack(spacing: 13) {
                GuardIcon(.circleQuestion, size: 25).foregroundStyle(GuardVisual.text)
                VStack(alignment: .leading, spacing: 5) {
                    Text(language.text("核验信息", "Verification")).font(.system(size: 12, weight: .medium))
                    Text(verificationSubtitle).contentTransition(.opacity).animation(resultAnimation, value: service.isRechecking).font(.system(size: 11)).foregroundStyle(GuardVisual.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                HStack(spacing: 7) {
                    Text(service.isRechecking ? language.text("—项提醒", "— alerts") : language.text("\(service.verificationReminderCount)项提醒", "\(service.verificationReminderCount) alerts")).foregroundStyle(GuardVisual.clay)
                    Text("·").foregroundStyle(GuardVisual.muted)
                    Text(service.isRechecking ? language.text("—项未验证", "— unverified") : language.text("\(service.verificationUnknownCount)项未验证", "\(service.verificationUnknownCount) unverified")).foregroundStyle(GuardVisual.secondary)
                }.font(.system(size: 10)).fixedSize()
                GuardIcon(.chevronRight, size: 14).foregroundStyle(GuardVisual.secondary)
            }.padding(.horizontal, 16).frame(height: 68).contentShape(Rectangle())
        }.buttonStyle(.plain).background(panelBackground(corner: 10))
            .disabled(service.isRechecking)
            .popover(isPresented: $showVerification) { verificationDetails }
    }

    private var verificationSubtitle: String {
        if service.isRechecking { return language.text("正在更新核验信息…", "Updating verification…") }
        if service.snapshot.client == nil { return language.text("尚未取得客户端核验信息", "Client verification is unavailable") }
        let messages = service.verificationFindings.compactMap { item -> String? in
            guard item.state != .passed && item.state != .information else { return nil }
            switch item.id {
            case "signature": return item.value.text(language)
            case "network":
                if let country = service.snapshot.network?.countryCode, !GuardSupportedRegions.codes.contains(country), item.state == .attention {
                    return language.text("出口地区未列入支持范围", "Route outside supported regions")
                }
                if item.state == .attention { return language.text("出口与地区不同", "Route differs from region") }
                return item.value.text(language)
            default: return item.value.text(language)
            }
        }
        return messages.isEmpty ? language.text("来源、网络与网页层已核验", "Source, route and page verified") : messages.joined(separator: " · ")
    }

    private func panelBackground(corner: CGFloat = GuardVisual.corner) -> some View {
        RoundedRectangle(cornerRadius: corner).fill(GuardVisual.card)
            .overlay { RoundedRectangle(cornerRadius: corner).strokeBorder(GuardVisual.line, lineWidth: 1) }
    }
    private var separator: some View { Rectangle().fill(GuardVisual.line).frame(height: 1) }

    private func dropdown(title: String, value: String, key: String, options: [(String, String)], select: @escaping (String) -> Void) -> some View {
        HStack(spacing: 5) {
            Text(value).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            GuardIcon(.chevronDown, size: 13).foregroundStyle(GuardVisual.secondary)
        }.padding(.horizontal, 9).frame(height: 31)
            .background(GuardVisual.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(missingField == key ? GuardVisual.clay : Color.white.opacity(0.1), lineWidth: missingField == key ? 1.4 : 1) }
            .overlay { GuardDropdownHitArea(title: title, value: value, options: options) { selection in missingField = nil; select(selection) } }
            .accessibilityElement(children: .contain)
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("评分规则", "Scoring rules")).font(.system(size: 15, weight: .semibold))
            Text(language.text("本地环境特征：最高 40 分\n地区为中国大陆或使用中国大陆时区时计 40 分，不重复累计；中文语言本身不计分。\n\n网络出口参照：最高 40 分\n探测国家不在已核对的支持地区列表中计 40 分，地区不一致只作提醒。\n\n客户端校验：最高 20 分\n有效签名 0 分；本地重签名 10 分；签名或资源校验失败 20 分。\n\n0–19：风险较低；20–49：风险中等；50–79：风险较高；80–100：风险很高。缺失必要检测数据时不计算总分。", "Local environment: up to 40. Mainland China region or timezone adds 40 once; Chinese language alone adds none.\n\nNetwork reference: up to 40 for a country outside the checked supported-region list.\n\nClient: valid signature 0; local signature 10; failed validation 20.\n\n0–19 lower, 20–49 moderate, 50–79 higher, 80–100 very high. Missing required data leaves the total unavailable."))
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }.padding(18).frame(width: 350)
    }
    private var verificationDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(service.verificationFindings) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title.text(language) + " · " + item.value.text(language)).font(.system(size: 13, weight: .semibold))
                    Text(item.detail.text(language)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(language.text("只读检测出口国家", "Read-only route-country checks"), isOn: Binding(get: { service.networkChecksEnabled }, set: { enabled in service.setNetworkChecksEnabled(enabled) }))
                .toggleStyle(.switch).controlSize(.small)
            Button(language.text("选择 Claude 安装位置…", "Choose Claude app…")) { service.selectApplication() }
        }.padding(18).frame(width: 360)
    }

    private var checkAge: String {
        guard let date = service.snapshot.checkedAt else { return language.text("待检测", "Not checked") }
        if service.isDesignPreview || date.timeIntervalSinceNow > -60 { return language.text("刚刚检测", "Just checked") }
        return Fmt.ago(date, language: language) + language.text("前检测", " ago")
    }
    private func languageName(_ code: String, includeCode: Bool = true) -> String {
        guard !code.isEmpty else { return "—" }
        let name: String
        if code.hasPrefix("zh") { name = code.contains("Hant") || code.contains("TW") || code.contains("HK") ? "繁體中文" : "简体中文" }
        else { name = Locale(identifier: "en").localizedString(forLanguageCode: Locale(identifier: code).language.languageCode?.identifier ?? code)?.capitalized ?? code }
        return includeCode ? "\(name) (\(code))" : name
    }
    private func regionName(_ identifier: String, includeCode: Bool = true) -> String {
        guard !identifier.isEmpty, let code = Locale(identifier: identifier).region?.identifier else { return language.text("选择地区", "Choose region") }
        let name = language == .chinese && code == "CN" ? "中国" : displayLocale.localizedString(forRegionCode: code) ?? code
        return includeCode ? "\(name) (\(identifier))" : name
    }
    private var launchTitle: String {
        if service.isLaunching { return language.text("正在启动…", "Launching…") }
        if isRunning {
            return canApplyWhileRunning ? language.text("应用配置并重新启动 Claude", "Apply profile and restart Claude")
                                        : language.text("Claude 正在运行", "Claude is running")
        }
        return service.profile.enabled ? language.text("应用配置并启动 Claude", "Apply profile and launch Claude") : language.text("启动 Claude", "Launch Claude")
    }
    private func launch() {
        guard !service.isDesignPreview else { return }
        if service.profile.enabled && !service.profile.isValid {
            if !GuardProfile.languages.contains(service.profile.languageCode) { missingField = "language" }
            else if !Locale.Region.isoRegions.contains(where: { $0.identifier == service.profile.countryCode }) { missingField = "region" }
            else { missingField = "timezone" }
            return
        }
        if isRunning {
            guard canApplyWhileRunning else { return }
            let alert = NSAlert()
            alert.messageText = language.text("应用配置并重启 Claude？", "Apply profile and restart Claude?")
            alert.informativeText = language.text("将使用当前的语言、地区和时区重新启动 Claude。", "Claude will restart with the saved language, locale and timezone.")
            alert.addButton(withTitle: language.text("重启并应用", "Restart and apply"))
            alert.addButton(withTitle: language.text("取消", "Cancel"))
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task { if !(await service.restartWithProfile()) { showFailure() } }
        } else {
            Task { if !(await service.launchClaude()) { showFailure() } }
        }
    }
    private func setProfileEnabled(_ enabled: Bool) {
        var value = service.profile; value.enabled = enabled; service.updateProfile(value)
        let running = service.isDesignPreview ? service.snapshot.client?.pid != nil : !GuardLauncher.runningApplications.isEmpty
        guard !enabled, running else { return }
        let alert = NSAlert()
        alert.messageText = language.text("是否重启 Claude？", "Restart Claude?")
        alert.informativeText = language.text("专属配置已关闭，重启后将使用系统配置。", "The launch profile is off. Restart to use the system configuration.")
        alert.addButton(withTitle: language.text("重启 Claude", "Restart Claude"))
        alert.addButton(withTitle: language.text("稍后", "Later"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        if alert.runModal() == .alertFirstButtonReturn {
            guard !service.isDesignPreview else { return }
            Task { if !(await service.restartWithoutProfile()) { showFailure() } }
        }
    }
    private func showFailure() {
        let alert = NSAlert()
        alert.messageText = language.text("Claude 启动未完成", "Claude could not be launched")
        alert.informativeText = service.operationMessage?.text(language) ?? language.text("请稍后重试。", "Please try again.")
        alert.addButton(withTitle: language.text("好", "OK"))
        alert.runModal()
    }
}

/// Keep the arc and counter alive across loading, so completion animates instead of inserting a full ring.
private struct GuardRiskGauge: View {
    let total: Int?
    let caption: String
    let compact: Bool
    let checking: Bool
    let checkingLabel: String
    let unknownLabel: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0

    private var size: CGFloat { compact ? 43 : 118 }
    private var line: CGFloat { compact ? 3 : 7 }

    var body: some View {
        ZStack {
            Circle().inset(by: line / 2).stroke(Color.black.opacity(0.35), lineWidth: line)
            Circle().inset(by: line / 2).trim(from: 0, to: progress)
                .stroke((total.map { (0..<20).contains($0) } ?? false) ? Color.white : GuardVisual.clay,
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(checking || total == nil ? 0 : 1)
            VStack(spacing: compact ? 0 : 5) {
                ZStack {
                    GuardAnimatedScore(value: progress * 100)
                        .opacity(checking || total == nil ? 0 : 1)
                    Text("—").opacity(!checking && total == nil ? 1 : 0)
                    if checking { ProgressView().controlSize(compact ? .mini : .small) }
                }
                .font(.system(size: compact ? 16 : 38, weight: .semibold)).monospacedDigit()
                .frame(height: compact ? 19 : 45)
                if !compact { Text(caption).font(.system(size: 10, weight: .medium)).foregroundStyle(GuardVisual.secondary) }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore).accessibilityLabel(caption)
        .accessibilityValue(checking ? checkingLabel : total.map(String.init) ?? unknownLabel)
        .onAppear { updateProgress(animated: false) }
        .onChange(of: checking) { _, _ in updateProgress(animated: !checking) }
        .onChange(of: total) { _, _ in updateProgress(animated: !checking) }
        .onChange(of: reduceMotion) { _, _ in updateProgress(animated: false) }
    }

    private func updateProgress(animated: Bool) {
        let target = checking ? 0 : Double(min(100, max(0, total ?? 0))) / 100
        let animation: Animation? = animated && total != nil && !reduceMotion ? .easeInOut(duration: 0.5) : nil
        var transaction = Transaction(animation: animation)
        if animation == nil { transaction.disablesAnimations = true }
        withTransaction(transaction) { progress = target }
    }
}

/// The same interpolated value drives the numeric score and the arc's trim.
private struct GuardAnimatedScore: View, Animatable {
    nonisolated var value: Double
    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View { Text(String(Int(value.rounded()))) }
}

private struct GuardActionStyle: ButtonStyle {
    let primary: Bool
    var height: CGFloat = 40
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: enabled ? .semibold : .medium)).frame(height: height)
            .foregroundStyle(enabled ? Color.white : GuardVisual.secondary)
            .background(RoundedRectangle(cornerRadius: 7).fill(enabled ? GuardVisual.clay : Color.white.opacity(0.08)))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.05), lineWidth: 1) }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct GuardSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? GuardVisual.clay : Color.white.opacity(0.2))
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 16, height: 16).padding(3)
                }.frame(width: 38, height: 22).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

private struct GuardWindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}


/// A full-size native hit target, independent of the system menu label's intrinsic width.
private struct GuardDropdownHitArea: NSViewRepresentable {
    let title: String
    let value: String
    let options: [(String, String)]
    let select: (String) -> Void

    func makeNSView(context: Context) -> GuardDropdownButton { GuardDropdownButton() }
    func updateNSView(_ button: GuardDropdownButton, context: Context) {
        button.isEnabled = context.environment.isEnabled
        button.options = options
        button.selection = select
        button.value = value
        button.setAccessibilityLabel(title)
        button.setAccessibilityValue(value)
        button.toolTip = value
    }
}

private final class GuardDropdownButton: NSButton {
    var options: [(String, String)] = []
    var selection: ((String) -> Void)?
    var value = ""

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        target = self
        action = #selector(openMenu)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {}

    @objc private func openMenu() {
        let menu = NSMenu()
        for (index, option) in options.enumerated() {
            let item = NSMenuItem(title: option.1, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = option.0 == value || option.1 == value ? .on : .off
            menu.addItem(item)
        }
        EnvironmentGuardWindow.activePopupMenu = menu
        let escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                MainActor.assumeIsolated { menu.cancelTracking() }
                return nil
            }
            return event
        }
        defer {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            EnvironmentGuardWindow.activePopupMenu = nil
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.minY), in: self)
    }
    @objc private func choose(_ sender: NSMenuItem) { selection?(options[sender.tag].0) }
}
