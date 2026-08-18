import AppKit
import CodexWidgetShared
import SwiftUI

enum CodexWidgetRender {
    @MainActor
    static func run() throws {
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--compare" {
            try ComparisonRenderer.render(
                referencePath: CommandLine.arguments[2],
                implementationPath: CommandLine.arguments[3],
                outputPath: CommandLine.arguments[4]
            )
            return
        }
        let output = CommandLine.arguments.dropFirst().first
            ?? FileManager.default.currentDirectoryPath + "/codex-widget-preview.png"
        let remaining = CommandLine.arguments.count > 2
            ? (Double(CommandLine.arguments[2]) ?? 0.72)
            : 0.72
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let reset = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 24, hour: 18
        ))
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 17, hour: 18
        ))!
        let fetchedAt = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 17, hour: 17, minute: 10
        ))!
        let snapshot = CodexWidgetSnapshot(
            remainingFraction: remaining,
            resetsAt: reset,
            fetchedAt: fetchedAt
        )
        let view = CodexQuotaCard(
            snapshot: snapshot,
            now: now
        )
        .frame(width: 364, height: 170)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 364, height: 170)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw RenderError.failed
        }
        try png.write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}

private enum RenderError: Error {
    case failed
}

try MainActor.assumeIsolated {
    try CodexWidgetRender.run()
}
