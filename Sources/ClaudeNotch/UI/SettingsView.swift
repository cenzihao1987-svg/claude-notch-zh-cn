import SwiftUI

private let clay = Color(red: 0.85, green: 0.47, blue: 0.34)

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = LoginItem.isEnabled

    private var language: AppLanguage { model.language }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                appearance
                display
                dataAccess
                general
            }
            .formStyle(.grouped)
            footer
        }
        .tint(clay)
        // A grouped Form has no intrinsic height — without this the hosting window collapses.
        .frame(width: 500, height: 790)
    }

    // MARK: 外观

    private var appearance: some View {
        Section(language.text("外观", "Appearance")) {
            HStack(spacing: 10) {
                ForEach(AvatarStyle.allCases) { style in
                    AvatarOption(style: style,
                                 title: avatarLabel(style),
                                 selected: model.avatarStyle == style) {
                        model.setAvatar(style)
                    }
                }
            }
            .padding(.vertical, 4)

            Toggle(isOn: Binding(get: { model.animateIcon },
                                 set: { _ in model.toggleAnimateIcon() })) {
                rowLabel(language.text("图标动画", "Animate icon"),
                         language.text("额度越紧张，动得越快；暂停或用满时静止",
                                       "Faster as quota runs low; still when paused or exhausted"))
            }

            LabeledContent(language.text("语言", "Language")) {
                Picker("", selection: Binding(get: { model.language },
                                              set: { model.setLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    // MARK: 显示

    private var display: some View {
        Section(language.text("显示", "Display")) {
            Toggle(language.text("全屏时隐藏", "Hide in full screen"),
                   isOn: Binding(get: { model.hideInFullscreen },
                                 set: { _ in model.toggleHideInFullscreen() }))

            Toggle(isOn: Binding(get: { model.showDesktopWidget },
                                 set: { _ in model.toggleDesktopWidget() })) {
                rowLabel(language.text("Codex 桌面小组件", "Codex desktop widget"),
                         language.text("在桌面单独放一个 Codex 额度卡片，不用展开刘海",
                                       "A standalone Codex quota card on the desktop, no need to expand the notch"))
            }
        }
    }

    // MARK: 数据获取

    private var dataAccess: some View {
        Section(language.text("数据获取", "Data access")) {
            // The menu offered "pause monitoring" as an action; a switch reads better here, so the
            // sense is inverted — on means monitoring is running.
            Toggle(language.text("额度监测", "Quota monitoring"),
                   isOn: Binding(get: { !model.isPaused },
                                 set: { _ in model.togglePause() }))

            Toggle(isOn: Binding(get: { model.claudeCredentialFallbackEnabled },
                                 set: { _ in model.toggleClaudeCredentialFallback() })) {
                rowLabel(language.text("Claude 备用获取", "Claude fallback access"),
                         language.text(
                            "Claude Desktop 的缓存过期时，用它的登录凭据直接向 claude.ai 问一次用量。首次需要一次钥匙串授权。",
                            "When the Claude Desktop cache goes stale, use its credentials to ask claude.ai for usage directly. Needs one Keychain authorization the first time."))
            }

            LabeledContent(language.text("立即刷新", "Refresh now")) {
                Button(language.text("刷新", "Refresh")) { model.refreshNow() }.tint(nil)
            }
        }
    }

    // MARK: 通用

    private var general: some View {
        Section(language.text("通用", "General")) {
            Toggle(language.text("开机自启", "Launch at login"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, _ in
                    LoginItem.toggle()
                    launchAtLogin = LoginItem.isEnabled
                }

            LabeledContent(language.text("软件更新", "Software update")) {
                Button(language.text("检查更新…", "Check for updates…")) {
                    Updater.shared.checkForUpdates()
                }
                .tint(nil)
            }
        }
    }

    // MARK: 底栏

    private var footer: some View {
        HStack {
            Text("Claude Notch v\(AppInfo.version) · "
                 + language.text(AppInfo.tagline, "Claude, Codex & DeepSeek"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(language.text("退出", "Quit")) { NSApp.terminate(nil) }.tint(nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    @ViewBuilder private func rowLabel(_ title: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func avatarLabel(_ style: AvatarStyle) -> String {
        switch style {
        case .clawd: "Clawd"
        case .clawdWhite: language.text("Clawd（单色）", "Clawd (Mono)")
        case .spark: "Spark"
        }
    }
}

private struct AvatarOption: View {
    let style: AvatarStyle
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                AvatarView(style: style, active: false)
                    .frame(height: 30)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selected ? clay.opacity(0.12) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? clay : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
