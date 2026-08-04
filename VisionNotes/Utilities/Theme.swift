import SwiftUI

/// The app's accent colour.
///
/// It is defined in code rather than as a colour asset so the project has no
/// asset-catalog colour to compile — one less thing to keep in sync between
/// light and dark mode, and the value is visible right here.
enum Theme {
    static let accent = Color(
        light: Color(red: 0.18, green: 0.40, blue: 0.78),
        dark: Color(red: 0.36, green: 0.56, blue: 0.90)
    )
}

extension Color {
    /// Picks between two colours based on the current interface style.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
    }
}
