#if DEBUG
import AppKit
import SwiftUI

enum GuardDemoScenario: String, CaseIterable, Identifiable {
    case repeated, anomalous, roundTrip, unverified, dualStack, longIPv6, sameCountry, inactive
    case clashRule, clashUnknown, connectionCombined, connectionHealthy
    case unprotectedLaunch, unprotectedCombined, welcome
    var id: String { rawValue }
    var title: String {
        switch self {
        case .repeated: "多地连续跳转 · 极高风险"
        case .anomalous: "单次异常跨区 · 较高风险"
        case .roundTrip: "短时跨区往返 · 极高风险"
        case .unverified: "出口定位待核验"
        case .dualStack: "IPv4 / IPv6 地区不一致"
        case .longIPv6: "IPv6 长内容 · 自适应高度"
        case .sameCountry: "同国换 IP · 提醒但不加分"
        case .inactive: "Claude 未运行 · 跨区变化豁免"
        case .clashRule: "Clash 规则模式 · 非全局提醒"
        case .clashUnknown: "Clash 模式无法核验"
        case .connectionCombined: "IP 改变＋Clash 非全局"
        case .connectionHealthy: "恢复正常 · 无连接预警"
        case .unprotectedLaunch: "未从刘海启动 · 以防护重启"
        case .unprotectedCombined: "未防护＋Clash 非全局"
        case .welcome: "首次运行 · 欢迎卡"
        }
    }
}

/// A separate DEBUG-only process: no account providers, monitor, updater, or production storage.
@MainActor
final class GuardNotchDemo: NSObject, NSWindowDelegate {
    let model: AppModel
    private let island: IslandWindow
    private let controls: NSWindow
    private var timer: Timer?
    private var restoring = false
    private let productionWasRunning = NSWorkspace.shared.runningApplications.contains {
        $0.bundleURL?.path == "/Applications/Claude Notch.app"
    }

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--guard-notch-demo")
            || Bundle.main.bundleIdentifier == "com.claudenotch.guard-demo"
    }

    static func makeModel() -> AppModel {
        let token = UUID().uuidString
        let service = EnvironmentGuardService(defaults: UserDefaults(suiteName: "guard-demo-" + token)!,
            historyStore: .init(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("guard-demo-" + token).appendingPathComponent("history.json")))
        return AppModel(environmentGuard: service)
    }

    init(model: AppModel, screen: NSScreen) {
        self.model = model
        island = IslandWindow(model: model, screen: screen, onExpansionChange: {})
        controls = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 290),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        // Two notch overlays would stack; the official notch quits normally and reopens at the end.
        NSWorkspace.shared.runningApplications
            .filter { $0.bundleURL?.path == "/Applications/Claude Notch.app" }
            .forEach { $0.terminate() }
        model.loadGuardDemo(.connectionCombined)
        controls.title = "刘海预警演示 · 假数据"
        controls.isReleasedWhenClosed = false
        controls.level = .floating
        controls.hidesOnDeactivate = false
        controls.delegate = self
        let hosting = NSHostingView(rootView: GuardDemoControls(model: model,
            show: { [weak self] scenario in self?.show(scenario) },
            expand: { [weak self] in self?.island.presentNetworkWarning() },
            collapse: { [weak self] in self?.island.presentation.isExpanded = false }))
        controls.contentView = hosting
        controls.setContentSize(hosting.fittingSize)
        controls.center()
        island.relayout(on: screen)
        island.show()
        island.presentNetworkWarning()
        controls.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak model] _ in
            Task { @MainActor in model?.environmentGuard.refreshGuardDemoClock() }
        }
    }

    private func show(_ scenario: GuardDemoScenario) {
        model.loadGuardDemo(scenario)
        island.presentNetworkWarning()
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    func restoreProductionNotch() {
        guard !restoring else { return }
        restoring = true
        timer?.invalidate()
        island.close()
        guard productionWasRunning else { return }
        // This opens only the quota/guard utility. It never launches Claude Desktop.
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Claude Notch.app"))
    }
}

/// Offscreen renders of the notch for comparison with the approved mockup. Synthetic data only;
/// nothing is launched, quit, or written outside a temporary directory.
@MainActor
enum NotchRenderFixture {
    static func render(_ name: String, to output: String) {
        let model = GuardNotchDemo.makeModel()
        let service = model.environmentGuard
        let scenario: GuardDemoScenario = switch name {
        case "unprotected", "collapsed": .unprotectedLaunch
        case "combined": .unprotectedCombined
        case "welcome": .welcome
        default: .connectionCombined
        }
        model.loadGuardDemo(scenario)
        service.reconcileRiskBanner()
        let clashID = service.riskItems.first { $0.action == .openClash }?.id
        switch name {
        case "checking": if let clashID { service.openClashForRisk(clashID, language: .chinese) }
        case "resolved":
            service.applyClashObservation(.global, activity: .active)
            service.reconcileRiskBanner()
        case "allclear":
            service.applyClashObservation(.global, activity: .active)
            service.reconcileRiskBanner()
            service.confirmExitForRisk()
        default: break
        }
        let content: AnyView
        let presentation = IslandPresentationState(screen: NSScreen.main ?? NSScreen.screens[0])
        presentation.notchWidth = 185
        presentation.topInset = 32
        presentation.isExpanded = name != "collapsed"
        if name == "hover" {
            content = AnyView(NetworkWarningView(service: service, language: .chinese, animate: false, measuredHeight: { _ in },
                initialHoveredRow: clashID).frame(width: 672).padding(24).background(Color.black))
        } else {
            content = AnyView(IslandView(model: model, presentation: presentation))
        }
        let host = NSHostingView(rootView: content)
        // 挂在刘海屏上取 Retina 倍率：外接 1x 主屏时，效果图才不会退成 1 倍。
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600), styleMask: .borderless, backing: .buffered, defer: false, screen: NSScreen.island)
        window.contentView = host
        func fit() {
            let size: NSSize
            if name == "hover" { size = host.fittingSize }
            else if presentation.isExpanded { size = NSSize(width: model.expandedIslandWidth, height: 32 + model.expandedDropHeight) }
            else { size = NSSize(width: model.collapsedIslandWidth(notchWidth: 185), height: 32) }
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
        }
        fit()
        // Measured banner/welcome heights settle after the first layout pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            fit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                fit()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
                }
                NSApp.terminate(nil)
            }
        }
    }
}

private struct GuardDemoControls: View {
    let model: AppModel
    let show: (GuardDemoScenario) -> Void
    let expand: () -> Void
    let collapse: () -> Void
    @State private var scenario = GuardDemoScenario.connectionCombined

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("临时演示 · 全部为假数据").font(.system(size: 16, weight: .semibold))
            Text("不联网、不写真实记录；不会启动或关闭 Claude。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("场景", selection: $scenario) {
                ForEach(GuardDemoScenario.allCases) { item in Text(item.title).tag(item) }
            }.onChange(of: scenario) { _, value in show(value) }
            HStack {
                Text("演示风险：\(model.environmentGuard.configuredRisk.total.map(String.init) ?? "—") / 100")
                Spacer()
                Button("重新触发") { show(scenario) }
            }.font(.system(size: 12))
            Text(model.environmentGuard.snapshot.desktopActivity == .inactive ? "演示实例未运行，后续出口变化只记录、不新增累计。" : model.environmentGuard.snapshot.client?.pid == nil ? "已模拟关闭 Claude，实际客户端未受影响。" : "可点击行内按钮、悬停一行后点左上角 × 忽略，以及“关闭 Claude”验收交互。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("收起刘海", action: collapse)
                Button("展开刘海", action: expand)
                Button("历史日志") { NetworkHistoryWindow.present(service: model.environmentGuard, language: model.language) }
                Button("守护面板") { EnvironmentGuardWindow.present(model: model, on: NSScreen.main) }
                Spacer()
            }
            Button("结束演示，恢复正常刘海") { NSApp.terminate(nil) }
                .buttonStyle(.borderedProminent).tint(AppPalette.accent)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(20).frame(width: 390, alignment: .leading)
    }
}
#endif
