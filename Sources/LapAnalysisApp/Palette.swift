import SwiftUI

/// Colours for laps and the speed gradient on the track map.
enum Palette {
    static let lapColors: [Color] = [
        Color.blue, Color.orange, Color.purple, Color.pink, Color.teal,
        Color.brown, Color.indigo, Color.cyan, Color.yellow, Color.mint
    ]

    static func color(_ index: Int) -> Color {
        let n: Int = lapColors.count
        let i: Int = ((index % n) + n) % n
        return lapColors[i]
    }

    /// t in 0...1: slow = red, fast = green.
    static func speedColor(_ t: Double) -> Color {
        let clamped: Double = min(max(t, 0), 1)
        return Color(hue: 0.33 * clamped, saturation: 0.85, brightness: 0.9)
    }
}
