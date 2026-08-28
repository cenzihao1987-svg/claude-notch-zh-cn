import AppKit
import SwiftUI

public struct CodexQuotaCard: View {
    private let snapshot: CodexWidgetSnapshot?
    private let now: Date
    private let language: CodexWidgetLanguage

    public init(
        snapshot: CodexWidgetSnapshot?,
        now: Date = Date(),
        language: CodexWidgetLanguage = .chinese
    ) {
        self.snapshot = snapshot
        self.now = now
        self.language = language
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                cardBackground
                HStack(spacing: 12) {
                    details
                        .frame(width: proxy.size.width * 0.45, alignment: .leading)
                    Spacer(minLength: 0)
                    percentage
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .layoutPriority(1)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 17)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                codexIcon
                    .frame(width: 29, height: 29)
                Text("Codex")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 9)
            Text(text("7 天额度", "7-day quota"))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))
            Spacer(minLength: 7)
            segmentedProgress
                .frame(height: 18)
            Spacer(minLength: 8)
            Text(resetLabel)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(secondaryAccent)
                .lineLimit(1)
            Spacer(minLength: 3)
            Text(detailLabel)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(.white.opacity(0.40))
                .lineLimit(1)
        }
    }

    private var codexIcon: some View {
        Group {
            if let url = Bundle.main.url(forResource: "codex-widget-icon", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if let url = Bundle.module.url(
                forResource: "codex-widget-icon", withExtension: "png"
            ), let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "terminal.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .foregroundStyle(primaryAccent)
            }
        }
        .accessibilityHidden(true)
    }

    private var segmentedProgress: some View {
        HStack(spacing: 3) {
            ForEach(0..<24, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(segmentColor(at: index))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var percentage: some View {
        percentageText
        .minimumScaleFactor(0.65)
        .lineLimit(1)
        .foregroundStyle(accentGradient)
        .shadow(color: primaryAccent.opacity(0.16), radius: 12)
    }

    private var percentageText: Text {
        guard let snapshot else {
            return Text("—").font(.system(size: 84, weight: .bold, design: .default))
        }
        let number = String(Int((snapshot.remainingFraction * 100).rounded()))
        return Text(number)
            .font(.system(size: 84, weight: .bold, design: .default))
            .tracking(-4)
            + Text("%").font(.system(size: 38, weight: .bold, design: .default))
    }

    private var cardBackground: some View {
        ZStack {
            Color(red: 0.018, green: 0.024, blue: 0.034)
            RadialGradient(
                colors: [primaryAccent.opacity(0.12), .clear],
                center: UnitPoint(x: 0.78, y: 0.40),
                startRadius: 0,
                endRadius: 170
            )
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var remainingFraction: Double { snapshot?.remainingFraction ?? 0 }

    private var filledSegments: Int {
        snapshot == nil ? 0 : Int((remainingFraction * 24).rounded())
    }

    private func segmentColor(at index: Int) -> Color {
        guard index < filledSegments else { return .white.opacity(0.13) }
        if remainingFraction <= 0.20 {
            return Color(red: 1.0, green: 0.30, blue: 0.30)
        }
        if remainingFraction <= 0.40 {
            return Color(red: 1.0, green: 0.63, blue: 0.20)
        }
        let progress = Double(index) / 23
        return Color(
            red: 0.12 - (0.03 * progress),
            green: 0.84 - (0.34 * progress),
            blue: 0.88 + (0.10 * progress)
        )
    }

    private var primaryAccent: Color {
        if remainingFraction <= 0.20, snapshot != nil {
            return Color(red: 1.0, green: 0.30, blue: 0.30)
        }
        if remainingFraction <= 0.40, snapshot != nil {
            return Color(red: 1.0, green: 0.63, blue: 0.20)
        }
        return Color(red: 0.12, green: 0.82, blue: 0.91)
    }

    private var secondaryAccent: Color {
        if remainingFraction <= 0.40, snapshot != nil { return primaryAccent }
        return Color(red: 0.20, green: 0.45, blue: 1.0)
    }

    private var accentGradient: LinearGradient {
        if remainingFraction <= 0.40, snapshot != nil {
            return LinearGradient(
                colors: [primaryAccent.opacity(0.94), primaryAccent],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [
                Color(red: 0.16, green: 0.86, blue: 0.90),
                Color(red: 0.12, green: 0.34, blue: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var resetLabel: String {
        guard let reset = snapshot?.resetsAt else {
            return snapshot == nil
                ? text("等待同步额度", "Waiting for quota")
                : text("重置时间待同步", "Reset time unavailable")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .english ? "en_US" : "zh_CN")
        formatter.dateFormat = language == .english ? "MMM d" : "M月d日"
        let date = formatter.string(from: reset)
        return text("\(date)重置", "Resets \(date)")
    }

    private var detailLabel: String {
        guard let snapshot else {
            return text("打开 Claude Notch 后自动更新", "Open Claude Notch to update")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .english ? "en_US" : "zh_CN")
        formatter.dateFormat = "HH:mm"
        let update = text(
            "更新于 \(formatter.string(from: snapshot.fetchedAt))",
            "Updated \(formatter.string(from: snapshot.fetchedAt))"
        )
        guard let reset = snapshot.resetsAt else { return update }
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return text("即将重置 · \(update)", "Resetting soon · \(update)") }
        let days = max(1, Int(ceil(seconds / 86_400)))
        return text("还剩 \(days) 天 · \(update)", "\(days)d remaining · \(update)")
    }

    private var accessibilityLabel: String {
        guard let snapshot else {
            return text("Codex 7 天额度，等待同步", "Codex 7-day quota, waiting to sync")
        }
        let percent = Int((snapshot.remainingFraction * 100).rounded())
        return text(
            "Codex 7 天额度，剩余 \(percent)%，\(resetLabel)",
            "Codex 7-day quota, \(percent)% remaining, \(resetLabel)"
        )
    }

    private func text(_ chinese: String, _ english: String) -> String {
        language == .chinese ? chinese : english
    }
}
