import SwiftUI

struct NetworkHistoryView: View {
    let service: EnvironmentGuardService
    let language: AppLanguage
    @State private var entries: [GuardNetworkLogEntry] = []
    @State private var cursor: UInt64?
    @State private var loading = false
    @State private var failed = false
    @State private var skipped = 0
    @State private var hasNewRecords = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                GuardIcon(.clock, size: 17)
                Text(language.text("出口与风险历史", "Exit and risk history")).font(.system(size: 15, weight: .semibold))
                if service.isDesignPreview {
                    Text(language.text("演示日志", "Demo log")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if hasNewRecords { Text(language.text("有新记录", "New records")).font(.system(size: 10)).foregroundStyle(AppPalette.accent) }
                Button { Task { await load(reset: true) } } label: {
                    if loading { ProgressView().controlSize(.small).frame(width: 24, height: 24) }
                    else { GuardIcon(.refresh, size: 14).frame(width: 24, height: 24) }
                }.buttonStyle(.plain).disabled(loading)
                    .help(language.text("刷新历史日志", "Refresh history"))
                    .accessibilityLabel(language.text("刷新历史日志", "Refresh history"))
            }.padding(18)
            Divider().opacity(0.5)
            if failed && entries.isEmpty {
                message(language.text("无法读取历史日志", "Could not read history"),
                    subtitle: language.text("请稍后重试。", "Try again later."))
            } else if entries.isEmpty && !loading {
                message(skipped > 0 ? language.text("当前片段没有可读取的记录", "No readable records in this segment") : language.text("暂无历史日志", "No history yet"),
                    subtitle: skipped > 0 ? language.text("可尝试加载更早记录。", "Try loading older records.") : language.text("出口或风险发生变化后，会记录在这里。", "Exit and risk changes will appear here."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            NetworkHistoryRow(entry: entry, language: language).padding(.horizontal, 18)
                            Divider().opacity(0.4).padding(.horizontal, 18)
                        }
                        if cursor != nil {
                            Button { Task { await load(reset: false) } } label: {
                                Text(language.text(loading ? "加载中…" : "加载更早记录", loading ? "Loading…" : "Load older records"))
                                    .font(.system(size: 12)).frame(maxWidth: .infinity).padding(14)
                            }.buttonStyle(.plain).disabled(loading)
                        }
                    }
                }
            }
            Divider().opacity(0.5)
            HStack {
                Text(failed ? language.text("读取失败，请点击刷新重试", "Read failed; refresh to retry") : skipped > 0
                     ? (entries.isEmpty ? language.text("当前片段存在损坏记录", "This segment contains unreadable records") : language.text("部分记录损坏，已显示其余记录", "Some records could not be read"))
                     : language.text("已显示 \(entries.count) 条 · 仅本机记录", "Showing \(entries.count) · stored locally"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if entries.isEmpty, cursor != nil {
                    Button(language.text("加载更早记录", "Load older records")) { Task { await load(reset: false) } }
                        .font(.system(size: 11)).disabled(loading)
                }
            }.padding(.horizontal, 18).padding(.vertical, 11)
        }
        .background(AppPalette.window)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 350, idealHeight: 520)
        .task { await load(reset: true) }
        .onChange(of: service.exitLogRevision) { _, _ in hasNewRecords = true }
    }

    private func message(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 9) {
            GuardIcon(.clock, size: 27).foregroundStyle(.secondary)
            Text(title).font(.system(size: 14, weight: .medium))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor private func load(reset: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let revision = service.exitLogRevision
        do {
            let page = try await service.loadExitHistory(before: reset ? nil : cursor)
            if reset { entries = page.entries; skipped = page.skippedRecords }
            else { entries.append(contentsOf: page.entries); skipped += page.skippedRecords }
            cursor = page.nextOffset
            failed = false
            if reset { hasNewRecords = service.exitLogRevision != revision }
        } catch { failed = true }
    }
}

struct NetworkHistoryRow: View {
    let entry: GuardNetworkLogEntry
    let language: AppLanguage
    private var locale: Locale { Locale(identifier: language == .chinese ? "zh_CN" : "en_US") }
    private var risk: GuardLoggedRisk? { entry.risk }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.title(language)).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(entry.date, format: .dateTime.year().month().day().hour().minute().second())
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    if let previous = entry.previous, !previous.sameRoute(as: entry.exit) {
                        Text(location(previous) + " → " + location(entry.exit)).font(.system(size: 12))
                        Text(verbatim: previous.ip + " → " + entry.exit.ip)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    } else {
                        Text(location(entry.exit)).font(.system(size: 12))
                        Text(verbatim: entry.exit.ip).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 4) {
                    if let risk {
                        Text(language.text("专属风险 ", "Configured risk ") + transitionScore(risk.configuredTotal, previous: entry.previousRisk?.configuredTotal) + level(risk.configuredTotal))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(color(risk.configuredTotal))
                        Text(language.text("系统风险 ", "System risk ") + transitionScore(risk.systemTotal, previous: entry.previousRisk?.systemTotal))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Text(language.text("当时未记录评分", "Score not recorded"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.fixedSize()
            }
            if entry.kind == "rule-updated" {
                Text(language.text("旧记录缺少运行证据，原记录保留，未纳入新规则累计。", "Legacy records lack activity evidence; original records are retained and excluded from new confirmed counts."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(activityDescription).font(.system(size: 10)).foregroundStyle(.secondary)
            if let risk, let kind = risk.behavior {
                Text(GuardNetworkBehavior(kind: kind).title(language))
                    .font(.system(size: 10)).foregroundStyle(risk.locationUnverified ? Color.secondary : color(risk.configuredTotal))
            }
        }.padding(.vertical, 13)
    }

    private var activityDescription: String {
        switch risk?.desktopActivity ?? entry.exit.desktopActivity {
        case .active: language.text("出口采样时 Claude／可信执行进程运行中", "Claude or trusted execution was running at the exit sample")
        case .inactive: language.text("出口采样时 Claude 未运行 · 本次变化不新增风险累计", "Claude was not running at the sample · no added exposure count")
        case .unknown: language.text("采样时运行状态待核验 · 未计入已确认跨区累计", "Activity unverified · excluded from confirmed region counts")
        case nil: language.text("旧记录未保存运行状态", "Activity was not recorded in this legacy entry")
        }
    }

    private func location(_ exit: GuardExit) -> String {
        (locale.localizedString(forRegionCode: exit.country) ?? exit.country) + (exit.city.map { " · " + $0 } ?? "")
    }
    private func score(_ total: Int?) -> String { total.map(String.init) ?? "—" }
    private func transitionScore(_ current: Int?, previous: Int?) -> String {
        if let previous, previous != current { return String(previous) + " → " + score(current) }
        return score(current)
    }
    private func level(_ total: Int?) -> String {
        guard let total else { return "" }
        switch total {
        case 0..<20: return language.text(" · 较低", " · low")
        case 20..<50: return language.text(" · 中等", " · moderate")
        case 50..<80: return language.text(" · 较高", " · high")
        default: return language.text(" · 极高", " · very high")
        }
    }
    private func color(_ total: Int?) -> Color {
        guard let total else { return .secondary }
        return total >= 50 ? AppPalette.accent : total >= 20 ? Color(red: 0.86, green: 0.70, blue: 0.45) : .primary
    }
}
