import AppKit
import SwiftUI

/// Match the native grouped Settings form; resolve colors in the current window appearance.
enum AppPalette {
    static let accent = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let window = Color(nsColor: .controlBackgroundColor)
    // Same fill as Form(.grouped), verified in both Aqua and Dark Aqua renderings.
    static let group = Color.primary.opacity(0.035)
    static let field = Color.primary.opacity(0.04)
}
