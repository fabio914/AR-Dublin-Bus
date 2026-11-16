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

    // Inside cards (`PanelCard`, on `appCard`). Route badges keep `TFIColors.ink` on yellow
    // in both modes; these are for text and lines on the card itself.

    /// Main text on a card.
    static let cardInk = Color(light: UIColor(TFIColors.ink), dark: UIColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1))
    /// Secondary text on a card: stop numbers, details, timetable-only times.
    static let cardSecondaryInk = Color(light: UIColor(TFIColors.secondaryInk), dark: UIColor(red: 0.64, green: 0.66, blue: 0.69, alpha: 1))
    /// Hairlines between a card's rows.
    static let cardSeparator = Color(light: UIColor(TFIColors.separator), dark: UIColor(red: 0.26, green: 0.27, blue: 0.29, alpha: 1))
    /// The strip at the bottom of a card.
    static let cardFooter = Color(light: UIColor(red: 0.96, green: 0.97, blue: 0.97, alpha: 1), dark: UIColor(red: 0.21, green: 0.22, blue: 0.24, alpha: 1))
    /// Marks live times on a card.
    static let cardLive = Color(light: UIColor(TFIColors.live), dark: UIColor(TFIColors.liveOnDark))

    private init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}
