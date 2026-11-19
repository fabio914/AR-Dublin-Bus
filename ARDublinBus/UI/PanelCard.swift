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

    /// Where the header pins inside a scroll view using `stickyPanelHeaders()`; `nil` elsewhere.
    @Environment(\.panelHeaderPinTop) private var pinTop
    @State private var headerHeight: CGFloat = 0
    /// How far the header has slid down the card to stay pinned.
    @State private var headerOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            pinnableHeader
            content
        }
        .frame(maxWidth: .infinity)
        .background(Color.appCard)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .onGeometryChange(for: CGFloat.self) { [pinTop, headerHeight] proxy in
            guard let pinTop else { return 0 }
            return Self.pinnedOffset(cardFrame: proxy.frame(in: .scrollView(axis: .vertical)), headerHeight: headerHeight, pinTop: pinTop)
        } action: { headerOffset = $0 }
    }

    /// While pinned, the header has the card's top corners and the gap above it is filled with
    /// the screen's background, so it looks like the top of a card with the rest scrolling under.
    private var pinnableHeader: some View {
        let isPinned = headerOffset > 0
        let radius = PanelMetrics.cornerRadius
        return PanelHeader(title: title, subtitle: subtitle, accessory: accessory, favourite: favourite, icon: icon)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: isPinned ? radius : 0, topTrailingRadius: isPinned ? radius : 0, style: .continuous))
            .background(alignment: .top) {
                if isPinned {
                    Color.appBackground
                        .frame(height: PanelMetrics.pinnedHeaderGap + radius)
                        .offset(y: -PanelMetrics.pinnedHeaderGap)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            .offset(y: headerOffset)
            .zIndex(1)
    }

    /// Keeps the header at `pinTop` while the card scrolls under it, like a list's section
    /// header, until the card's bottom pushes it back up.
    static func pinnedOffset(cardFrame: CGRect, headerHeight: CGFloat, pinTop: CGFloat) -> CGFloat {
        min(max(pinTop - cardFrame.minY, 0), max(cardFrame.height - headerHeight, 0))
    }
}

extension EnvironmentValues {
    /// Where the header of a `PanelCard` pins, in the coordinates of the scroll view around it;
    /// `nil` when headers don't pin.
    @Entry var panelHeaderPinTop: CGFloat?
}

extension View {
    /// Pins the green header of each `PanelCard` in this scroll view near the top of the visible
    /// area (below any bar, after `PanelMetrics.pinnedHeaderGap`) while the rest of its card
    /// scrolls under it. Cards need at least that gap above them in the scroll view.
    func stickyPanelHeaders() -> some View {
        // The scroll view's coordinate space starts below its bars, so the gap is all it needs.
        environment(\.panelHeaderPinTop, PanelMetrics.pinnedHeaderGap)
    }
}

enum PanelMetrics {
    static let cornerRadius: CGFloat = 24
    static let horizontalPadding: CGFloat = 16
    /// The space above a pinned header (see `stickyPanelHeaders()`), as between cards.
    static let pinnedHeaderGap: CGFloat = 16
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
