import CodexWidgetShared
import SwiftUI
import WidgetKit

private struct CodexQuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: CodexWidgetSnapshot?
}

private struct CodexQuotaProvider: TimelineProvider {
    func placeholder(in context: Context) -> CodexQuotaEntry {
        CodexQuotaEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexQuotaEntry) -> Void) {
        completion(CodexQuotaEntry(
            date: Date(),
            snapshot: context.isPreview ? .preview : CodexWidgetSnapshotStore.load()
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexQuotaEntry>) -> Void) {
        let now = Date()
        let entry = CodexQuotaEntry(date: now, snapshot: CodexWidgetSnapshotStore.load())
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

private struct CodexQuotaWidgetView: View {
    let entry: CodexQuotaEntry

    var body: some View {
        CodexQuotaCard(snapshot: entry.snapshot, now: entry.date)
            .containerBackground(for: .widget) { Color.clear }
    }
}

private struct CodexQuotaWidget: Widget {
    let kind = "CodexQuotaWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexQuotaProvider()) { entry in
            CodexQuotaWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex 剩余额度")
        .description("查看 Codex 7 天额度的剩余百分比与重置时间。")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct CodexQuotaWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexQuotaWidget()
    }
}
