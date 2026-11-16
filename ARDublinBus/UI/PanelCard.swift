import SwiftUI

/// The card style shared by the AR panel and the in-app boards: a TFI-green header over a
/// card body. The body follows light and dark mode (see the `card…` colours); the AR panel
/// is rendered in light mode.
struct PanelCard<Content: View>: View {
    let title: String
    var subtitle: String?
    var accessory: PanelHeader.Accessory?
    var favourite: PanelHeader.Favourite?
    var icon = "bus.fill"
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: title, subtitle: subtitle, accessory: accessory, favourite: favourite, icon: icon)
            content
        }
        .frame(maxWidth: .infinity)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
    }
}

enum PanelMetrics {
    static let cornerRadius: CGFloat = 24
    static let horizontalPadding: CGFloat = 16
    static let footerBackground = Color.cardFooter
}

struct PanelHeader: View {
    /// A small label on the right of the header, e.g. a walking distance.
    struct Accessory {
        let systemImage: String
        let text: String
    }

    /// A star button on the right of the header, for starring the stop.
    struct Favourite {
        let isOn: Bool
        let toggle: () -> Void
    }

    let title: String
    var subtitle: String?
    var accessory: Accessory?
    var favourite: Favourite?
    var icon = "bus.fill"

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 15, weight: .medium))
                        .opacity(0.85)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let accessory {
                Label(accessory.text, systemImage: accessory.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.18), in: Capsule())
                    .fixedSize()
            }
            if let favourite {
                Button(action: favourite.toggle) {
                    Image(systemName: favourite.isOn ? "star.fill" : "star")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(favourite.isOn ? TFIColors.yellow : .white)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(favourite.isOn ? "Remove from favourites" : "Add to favourites")
                .sensoryFeedback(.selection, trigger: favourite.isOn)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TFIColors.green)
    }
}

/// A hairline between rows, inset like iOS lists.
struct PanelSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.cardSeparator)
            .frame(height: 1)
            .padding(.leading, PanelMetrics.horizontalPadding)
    }
}

/// The grey strip at the bottom of a card.
struct PanelFooter<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) {
            content
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color.cardSecondaryInk)
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(PanelMetrics.footerBackground)
    }
}

/// An icon, title and optional detail, centred in a card body.
struct PanelMessage: View {
    let icon: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.appTint)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.cardInk)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.cardSecondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
    }
}
