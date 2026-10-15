import AppKit
import SwiftUI

/// Lucide outline family, selected from iconfont collection 54062.
/// The original SVG geometry is bundled as native vector PDFs; no icon font is installed.
enum GuardGlyph: String, CaseIterable {
    case clock
    case shieldAlert = "shield-alert"
    case shieldCheck = "shield-check"
    case shieldQuestion = "shield-question-mark"
    case fileQuestion = "file-question-mark"
    case fileAlert = "file-exclamation-point"
    case languages, globe
    case appWindow = "app-window"
    case wifi
    case circleAlert = "circle-alert"
    case circleQuestion = "circle-question-mark"
    case chevronDown = "chevron-down"
    case chevronUp = "chevron-up"
    case chevronRight = "chevron-right"
    case settings, check
    case arrowDown = "arrow-down"
    case refresh = "refresh-cw"

    var hasLargeVariant: Bool { [.shieldAlert, .shieldCheck, .shieldQuestion].contains(self) }
}

@MainActor
enum GuardIconAssets {
    private static var cache: [String: NSImage] = [:]
    private static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("ClaudeNotch_ClaudeNotch.bundle"),
           let packaged = Bundle(url: url) { return packaged }
        return .module
    }()

    static func image(_ glyph: GuardGlyph, large: Bool = false) -> NSImage? {
        let name = glyph.rawValue + (large && glyph.hasLargeVariant ? "-large" : "")
        if let image = cache[name] { return image }
        guard let url = bundle.url(forResource: name, withExtension: "pdf", subdirectory: "GuardIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}

struct GuardIcon: View {
    let glyph: GuardGlyph
    var size: CGFloat = 20
    var large = false

    init(_ glyph: GuardGlyph, size: CGFloat = 20, large: Bool = false) {
        self.glyph = glyph
        self.size = size
        self.large = large
    }

    var body: some View {
        Group {
            if let image = GuardIconAssets.image(glyph, large: large) {
                Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
            } else { Color.clear }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
