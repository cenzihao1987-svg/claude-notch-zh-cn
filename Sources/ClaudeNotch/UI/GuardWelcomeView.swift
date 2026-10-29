import AppKit
import SwiftUI

/// Display names shared by the welcome card and the risk banner.
enum GuardDisplayNames {
    static func language(_ code: String) -> String {
        guard !code.isEmpty else { return "—" }
        if code.hasPrefix("zh") { return code.contains("Hant") || code.contains("TW") || code.contains("HK") ? "繁體中文" : "简体中文" }
        let locale = Locale(identifier: code)
        let name = Locale(identifier: "en").localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? code)?.capitalized ?? code
        return locale.region.map { "\(name) (\($0.identifier))" } ?? name
    }

    static func country(_ code: String, language: AppLanguage) -> String {
        guard !code.isEmpty else { return "—" }
        if language == .chinese && code == "CN" { return "中国" }
        return Locale(identifier: language == .chinese ? "zh_CN" : "en_US").localizedString(forRegionCode: code) ?? code
    }

    static func environment(language code: String, locale: String, timeZone: String, in language: AppLanguage) -> String {
        let region = Locale(identifier: locale).region?.identifier ?? ""
        return [Self.language(code), country(region, language: language), timeZone.isEmpty ? "—" : timeZone].joined(separator: " · ")
    }
}

/// First-run card on the Claude page: Claude is protected only when launched from the notch.
struct GuardWelcomeView: View {
    let service: EnvironmentGuardService
    let language: AppLanguage
    let openEnvironment: () -> Void
    let measuredHeight: (CGFloat) -> Void
    /// Applied only when the main button is pressed; "Later" changes nothing.
    @State private var launchAtLogin = true
    private let orange = Color(red: 0.89, green: 0.58, blue: 0.39)
    private var running: Bool { service.snapshot.client?.pid != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                GuardIcon(.shieldCheck, size: 26).foregroundStyle(orange)
                    .frame(width: 48, height: 48)
                    .background(orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                    .frame(width: 56, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("Claude 要从刘海启动，防护才生效", "Launch Claude from the notch to protect it"))
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    Text(language.text("从 Dock、启动台或聚焦搜索打开的 Claude，不会使用专属语言、地区和时区。完成下面三步，以后都从这里启动。",
                                       "Claude opened from the Dock, Launchpad or Spotlight doesn't use your dedicated language, region and timezone. Finish these three steps, then always launch it here."))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 6) {
                step(1, title: language.text("专属环境", "Launch profile")) {
                    Text(profileValue).font(.system(size: 11)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                    if service.profile.isValid && service.followingIP {
                        Text(language.text("按出口 IP 推荐", "Suggested by exit IP"))
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(orange)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(orange.opacity(0.18), in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Button(action: openEnvironment) {
                        HStack(spacing: 2) {
                            Text(language.text("修改", "Edit"))
                            GuardIcon(.chevronRight, size: 12)
                        }.font(.system(size: 10.5)).foregroundStyle(orange)
                    }.buttonStyle(.plain).disabled(service.isDesignPreview)
                }
                step(2, title: language.text("开机自动运行刘海", "Open notch at login")) {
                    Text(language.text("刘海不在运行时，无法为 Claude 提供防护", "Without the notch running, Claude can't be protected"))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                    Spacer(minLength: 0)
                    Toggle("", isOn: $launchAtLogin).labelsHidden().toggleStyle(WelcomeSwitchStyle())
                        .accessibilityLabel(language.text("开机自动运行刘海", "Open notch at login"))
                }
                step(3, title: language.text("从刘海启动 Claude", "Launch from the notch")) {
                    Text(language.text("启动前会先检查网络；以后也从这里启动", "The network is checked first; launch here from now on"))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }.padding(.top, 12)
            HStack(spacing: 8) {
                Text(language.text("只作用于从这里启动的 Claude，不修改系统设置", "Applies only to Claude launched here; system settings stay unchanged"))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                Spacer(minLength: 0)
                Button(language.text("稍后", "Later")) { service.dismissWelcome() }
                    .buttonStyle(WelcomeButtonStyle(primary: false))
                Button(action: enableAndLaunch) { Text(primaryTitle) }
                    .buttonStyle(WelcomeButtonStyle(primary: true))
                    .disabled(!service.profile.isValid || service.isLaunching || service.isClosingClaude)
            }.padding(.top, 12)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .background {
            GeometryReader { proxy in
                Color.clear.onAppear { measuredHeight(proxy.size.height) }
                    .onChange(of: proxy.size.height) { _, height in measuredHeight(height) }
            }
        }
        .onAppear { if LoginItem.isEnabled { launchAtLogin = true } }
    }

    private var profileValue: String {
        let profile = service.profile
        if profile.isValid {
            return GuardDisplayNames.environment(language: profile.languageCode, locale: profile.localeIdentifier,
                                                 timeZone: profile.timeZoneIdentifier, in: language)
        }
        if service.networkChecksEnabled && service.snapshot.networkError == nil {
            return language.text("正在按出口 IP 推荐…", "Suggesting from your exit IP…")
        }
        return language.text("未取得出口 IP，请点修改手动设置", "No exit IP yet; choose Edit to set it")
    }

    private var primaryTitle: String {
        if service.isLaunching { return language.text("正在启动…", "Launching…") }
        return running ? language.text("开启防护并重启 Claude", "Turn on protection and restart Claude")
                       : language.text("开启防护并启动 Claude", "Turn on protection and launch Claude")
    }

    private func enableAndLaunch() {
        if running, !service.isDesignPreview, !GuardRestartConfirmation.ask(state: .profileOff, language: language) { return }
        if launchAtLogin, !service.isDesignPreview, !LoginItem.isEnabled { LoginItem.toggle() }
        Task {
            let launched = await service.enableProtectionAndLaunch()
            if !launched, service.operationFailed { GuardRestartConfirmation.showFailure(service: service, language: language) }
        }
    }

    private func step<Content: View>(_ number: Int, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(number)")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(orange)
                .frame(width: 18, height: 18)
                .background(orange.opacity(0.18), in: Circle())
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white)
                .frame(width: 118, alignment: .leading)
            HStack(spacing: 6) { content() }
        }
        .padding(.vertical, 9).padding(.horizontal, 11)
        .frame(minHeight: 36)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct WelcomeButtonStyle: ButtonStyle {
    var primary: Bool
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: primary ? .semibold : .regular))
            .foregroundStyle(primary ? Color(red: 0.14, green: 0.086, blue: 0.05) : Color.white.opacity(0.7))
            .padding(.horizontal, primary ? 16 : 14).padding(.vertical, 7)
            .background(primary ? Color(red: 0.89, green: 0.58, blue: 0.39) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(primary ? Color.clear : Color.white.opacity(0.14), lineWidth: 1) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

/// 30 × 17 switch from the welcome mockup.
private struct WelcomeSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? Color(red: 0.89, green: 0.58, blue: 0.39) : Color.white.opacity(0.2))
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 13, height: 13).padding(2)
                }.frame(width: 30, height: 17).contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}
