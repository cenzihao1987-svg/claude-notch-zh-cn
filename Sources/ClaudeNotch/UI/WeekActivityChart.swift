import SwiftUI

/// Seven-day account-activity bar chart for the limits page: one bar per calendar day, today
/// highlighted, the peak day labeled with its count, and the week total in the header. Fills
/// whatever height the page gives it, so it works as the page's centerpiece tile.
struct WeekActivityChart: View {
    let series: [DailyUsagePoint]   // oldest first, today last
    var title = "近 7 天"
    var language: AppLanguage = .chinese
    var currency: String? = nil
    var note: String? = nil
    @State private var hoveredDate: Date?

    static let otherModelKey = "__other__"

    /// WorkBuddy's official feed contains decimal points, while Claude's local logs and DeepSeek
    /// exports use money. The optional fields make an all-zero week retain its correct unit.
    private var usesModelUsage: Bool { series.contains { $0.modelUsage != nil } }
    private var usesCredits: Bool { series.contains { $0.credits != nil } }
    private var usesCost: Bool {
        !usesModelUsage && !usesCredits && series.contains { $0.cost != nil }
    }
    private func value(_ point: DailyUsagePoint) -> Double {
        if usesCredits { return point.credits ?? 0 }
        return usesCost ? (point.cost ?? 0) : Double(point.tokens)
    }
    private func label(_ value: Double) -> String {
        if usesCredits {
            let text = String(format: "%.2f", value)
            return text.replacingOccurrences(of: #"\.0+$"#, with: "", options: .regularExpression)
        }
        return usesCost ? Fmt.amount(value, currency: currency ?? "USD") : Fmt.tokens(Int(value))
    }
    private var total: Double { series.reduce(0) { $0 + value($1) } }
    private var maxValue: Double { series.map(value).max() ?? 0 }
    private var modelKeys: [String] { Self.visibleModelKeys(in: series) }
    private var includesOtherModels: Bool {
        Self.hasOtherModels(in: series, visibleKeys: modelKeys)
    }
    private var legendKeys: [String] {
        modelKeys + (includesOtherModels ? [Self.otherModelKey] : [])
    }
    private var maxModelValue: Double {
        max(100, series.map { point in
            Self.displayedModelUsage(
                for: point,
                visibleKeys: modelKeys,
                includesOther: includesOtherModels
            ).reduce(0) { $0 + $1.value }
        }.max() ?? 0)
    }
    private var hasActivity: Bool {
        if usesModelUsage {
            return series.contains { point in
                (point.modelUsage ?? []).contains { $0.value > 0 }
            }
        }
        return maxValue > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                if let note {
                    Text(note).font(.system(size: 8.5))
                        .foregroundStyle(.white.opacity(0.32)).lineLimit(1)
                }
                Spacer()
                if !usesModelUsage, total > 0 {
                    Text(label(total)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            if usesModelUsage, !legendKeys.isEmpty {
                modelLegend
            }
            if !hasActivity {
                Spacer(minLength: 0)
                Text(usesModelUsage
                    ? language.text("本周暂无套餐用量", "No plan usage this week")
                    : language.text("本周暂无活动", "No activity this week"))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                GeometryReader { geo in
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(series) { point in
                            if usesModelUsage {
                                modelBar(point, available: geo.size.height)
                            } else {
                                bar(point, available: geo.size.height)
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    // Overlay the tooltip after layout so hover feedback never changes the
                    // chart's measured size or shifts the bars.
                    .overlay(alignment: .topTrailing) {
                        if usesModelUsage,
                           let hoveredDate,
                           let point = series.first(where: { $0.date == hoveredDate }) {
                            modelTooltip(point)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard usesModelUsage, !series.isEmpty else { return }
                        switch phase {
                        case let .active(location):
                            let slotWidth = geo.size.width / CGFloat(series.count)
                            let index = min(
                                series.count - 1,
                                max(0, Int(location.x / max(1, slotWidth)))
                            )
                            hoveredDate = series[index].date
                        case .ended:
                            hoveredDate = nil
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                ForEach(series) { point in
                    Text(dayLetter(point.date))
                        .font(.system(size: 8.5, weight: isToday(point.date) ? .bold : .regular))
                        .foregroundStyle(.white.opacity(isToday(point.date) ? 0.85 : 0.4))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var modelLegend: some View {
        HStack(spacing: 8) {
            ForEach(Array(legendKeys.enumerated()), id: \.element) { index, key in
                HStack(spacing: 3) {
                    Circle().fill(modelColor(key, index: index)).frame(width: 7, height: 7)
                    Text(modelName(key, compact: true))
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bar(_ point: DailyUsagePoint, available: CGFloat) -> some View {
        let v = value(point)
        let fraction = maxValue > 0 ? v / maxValue : 0
        let isPeak = v == maxValue && v > 0
        // ~12pt stays reserved for the peak label so the tallest bar never collides with it.
        let barHeight = max(3, (available - 14) * fraction)
        return VStack(spacing: 2) {
            Spacer(minLength: 0)
            if isPeak {
                Text(label(v))
                    .font(.system(size: 8.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1).fixedSize()
            }
            RoundedRectangle(cornerRadius: 2.5)
                .fill(.white.opacity(v == 0 ? 0.12 : (isToday(point.date) ? 0.9 : 0.4)))
                .frame(height: barHeight)
        }
        .frame(maxWidth: .infinity)
    }

    private func modelBar(_ point: DailyUsagePoint, available: CGFloat) -> some View {
        let segments = Self.displayedModelUsage(
            for: point,
            visibleKeys: modelKeys,
            includesOther: includesOtherModels
        )
        let total = segments.reduce(0) { $0 + $1.value }
        return Group {
            if total == 0 {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(.white.opacity(0.12))
                    .frame(height: 3)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(segments.reversed())) { segment in
                        let index = legendKeys.firstIndex(of: segment.model) ?? 0
                        Rectangle()
                            .fill(modelColor(segment.model, index: index))
                            .frame(height: max(1, available * segment.value / maxModelValue))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2.5))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .accessibilityLabel(modelAccessibilityLabel(point))
    }

    private func modelTooltip(_ point: DailyUsagePoint) -> some View {
        let segments = Self.displayedModelUsage(
            for: point,
            visibleKeys: modelKeys,
            includesOther: includesOtherModels
        )
        return VStack(alignment: .leading, spacing: 3) {
            Text(fullDate(point.date))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                HStack(spacing: 5) {
                    Circle().fill(modelColor(segment.model, index: index)).frame(width: 7, height: 7)
                    Text(modelName(segment.model, compact: false))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(Int(segment.value.rounded()))%")
                        .fontWeight(.semibold).monospacedDigit()
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.82))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(width: 178)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.white.opacity(0.12), lineWidth: 0.5))
    }

    static func visibleModelKeys(in series: [DailyUsagePoint], limit: Int = 3) -> [String] {
        var totals: [String: Double] = [:]
        for point in series {
            for segment in point.modelUsage ?? [] {
                totals[segment.model, default: 0] += segment.value
            }
        }
        return totals.keys.sorted { lhs, rhs in
            let left = totals[lhs] ?? 0
            let right = totals[rhs] ?? 0
            if left != right { return left > right }
            let leftPriority = modelPriority(lhs)
            let rightPriority = modelPriority(rhs)
            return leftPriority == rightPriority ? lhs < rhs : leftPriority < rightPriority
        }.prefix(limit).map { $0 }
    }

    static func hasOtherModels(in series: [DailyUsagePoint], visibleKeys: [String]) -> Bool {
        let allKeys = Set(series.flatMap { ($0.modelUsage ?? []).map(\.model) })
        return !allKeys.subtracting(visibleKeys).isEmpty
    }

    static func displayedModelUsage(
        for point: DailyUsagePoint,
        visibleKeys: [String],
        includesOther: Bool
    ) -> [ModelUsageSegment] {
        let raw = Dictionary(
            (point.modelUsage ?? []).map { ($0.model, $0.value) },
            uniquingKeysWith: +
        )
        var result = visibleKeys.map { ModelUsageSegment(model: $0, value: raw[$0] ?? 0) }
        if includesOther {
            let other = raw.reduce(0) { total, entry in
                visibleKeys.contains(entry.key) ? total : total + entry.value
            }
            result.append(ModelUsageSegment(model: otherModelKey, value: other))
        }
        return result
    }

    static func englishModelName(_ key: String, compact: Bool) -> String {
        if key == otherModelKey { return "Other" }
        let parts = key.split(separator: "-")
        guard parts.count >= 3, parts.first?.lowercased() == "gpt" else {
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
        let family = String(parts.last!).capitalized
        return compact ? family : "\(parts.dropLast().joined(separator: "-").uppercased()) \(family)"
    }

    private static func modelPriority(_ key: String) -> Int {
        if key.hasSuffix("-sol") { return 0 }
        if key.hasSuffix("-terra") { return 1 }
        if key.hasSuffix("-luna") { return 2 }
        return 3
    }

    private func modelName(_ key: String, compact: Bool) -> String {
        if key == Self.otherModelKey { return language.text("其他", "Other") }
        return Self.englishModelName(key, compact: compact)
    }

    private func modelColor(_ key: String, index: Int) -> Color {
        if key.hasSuffix("-sol") { return Color(red: 0.25, green: 0.50, blue: 0.96) }
        if key.hasSuffix("-terra") { return Color(red: 1.00, green: 0.61, blue: 0.34) }
        if key.hasSuffix("-luna") { return Color(red: 0.40, green: 0.84, blue: 0.57) }
        if key == Self.otherModelKey { return .white.opacity(0.28) }
        let palette = [
            Color(red: 0.63, green: 0.48, blue: 0.95),
            Color(red: 0.95, green: 0.43, blue: 0.65),
            Color(red: 0.92, green: 0.74, blue: 0.28),
        ]
        return palette[index % palette.count]
    }

    private func modelAccessibilityLabel(_ point: DailyUsagePoint) -> String {
        let values = Self.displayedModelUsage(
            for: point,
            visibleKeys: modelKeys,
            includesOther: includesOtherModels
        ).map { "\(modelName($0.model, compact: false)) \(Int($0.value.rounded()))%" }
        return ([fullDate(point.date)] + values).joined(separator: ", ")
    }

    private func isToday(_ date: Date) -> Bool { Calendar.current.isDateInToday(date) }

    private func dayLetter(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: language == .english ? "en_US" : "zh_Hans_CN")
        f.dateFormat = "EEEEE"   // narrow weekday, e.g. "M"
        return f.string(from: date)
    }

    private func fullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .english ? "en_US" : "zh_Hans_CN")
        formatter.dateFormat = language == .english ? "MMM d" : "M月d日"
        return formatter.string(from: date)
    }
}
