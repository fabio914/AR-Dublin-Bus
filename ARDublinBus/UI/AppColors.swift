import SwiftUI
import UIKit

/// The app's own screen colours. In dark mode the system's grouped background is pure black;
/// these are a step lighter, and the tint is a lighter green that stays readable on them.
extension Color {
    /// Behind every screen.
    static let appBackground = Color(light: .systemGroupedBackground, dark: UIColor(red: 0.11, green: 0.12, blue: 0.13, alpha: 1))
    /// Cards, form rows and fields on `appBackground`.
    static let appCard = Color(light: .secondarySystemGroupedBackground, dark: UIColor(red: 0.17, green: 0.18, blue: 0.2, alpha: 1))
    /// A field inside a card.
    static let appField = Color(light: .tertiarySystemGroupedBackground, dark: UIColor(red: 0.24, green: 0.25, blue: 0.27, alpha: 1))
    /// Tab bar selection, navigation items, links and plain buttons. TFI green in light mode.
    /// (Filled buttons keep `TFIColors.green`, which carries white text in both modes.)
    static let appTint = Color(light: UIColor(TFIColors.green), dark: UIColor(red: 0.36, green: 0.86, blue: 0.68, alpha: 1))

    private init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}
