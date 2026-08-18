import SwiftUI

struct Ring: View {
    var fraction: Double            // 0...1 elapsed
    var state: RingState
    var lineWidth: CGFloat = 4
    var drainsClockwise = false

    private var color: Color {
        switch state {
        case .ok: return Color(red: 0.36, green: 0.79, blue: 0.65)       // teal
        case .warn: return Color(red: 0.94, green: 0.62, blue: 0.15)     // amber
        case .critical: return Color(red: 0.89, green: 0.29, blue: 0.29) // red
        }
    }

    var body: some View {
        let clamped = min(1, max(0, fraction))
        let trimStart = drainsClockwise ? 1 - clamped : 0
        let trimEnd = drainsClockwise ? 1 : max(0.001, clamped)
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: trimStart, to: trimEnd)
                .stroke(color, style: .init(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: fraction)
        }
    }
}
