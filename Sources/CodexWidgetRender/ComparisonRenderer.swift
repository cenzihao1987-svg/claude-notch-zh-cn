import AppKit

@MainActor
enum ComparisonRenderer {
    static func render(referencePath: String, implementationPath: String, outputPath: String) throws {
        guard let reference = NSImage(contentsOfFile: referencePath),
              let implementation = NSImage(contentsOfFile: implementationPath),
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1528,
                pixelsHigh: 390,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { throw ComparisonError.failed }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1528, height: 390).fill()
        let hints: [NSImageRep.HintKey: Any] = [.interpolation: NSImageInterpolation.high.rawValue]
        reference.draw(
            in: NSRect(x: 24, y: 18, width: 728, height: 340),
            from: NSRect(x: 105, y: 240, width: 1070, height: 500),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: hints
        )
        implementation.draw(
            in: NSRect(x: 776, y: 18, width: 728, height: 340),
            from: NSRect(origin: .zero, size: implementation.size),
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: hints
        )
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
        ]
        NSString(string: "参考图").draw(at: NSPoint(x: 24, y: 365), withAttributes: attributes)
        NSString(string: "实现稿 · 72% 对齐状态").draw(
            at: NSPoint(x: 776, y: 365), withAttributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ComparisonError.failed
        }
        try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}

private enum ComparisonError: Error {
    case failed
}
