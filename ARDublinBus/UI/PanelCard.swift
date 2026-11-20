import SwiftUI

/// The card style shared by the AR panel and the in-app boards: a TFI-green header over a
/// card body, and an optional footer. The body follows light and dark mode (see the `card…`
/// colours); the AR panel is rendered in light mode.
///
/// Inside a `PanelCardStack` the card is a `Section`, so its header and footer pin to the
/// scroll view's edges while the body scrolls under them. Anywhere else it's drawn whole.
/// Either way, don't apply modifiers to it: in a stack they'd apply to each part separately.
struct PanelCard<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    var accessory: PanelHeader.Accessory?
    var favourite: PanelHeader.Favourite?
    var icon = "bus.fill"
    let footer: Footer?
    let content: Content

    @Environment(\.panelCardPins) private var pins
    @State private var isHeaderPinned = false
    @State private var isFooterPinned = false

    init(title: String, subtitle: String? = nil, accessory: PanelHeader.Accessory? = nil,
         favourite: PanelHeader.Favourite? = nil, icon: String = "bus.fill",
         footer: Footer?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.favourite = favourite
        self.icon = icon
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        if pins {
            Section {
                PanelCardPiece(edge: footer == nil ? .bottom : nil) {
                    content
                }
            } header: {
                PanelCardPiece(edge: .top) { header }
                    // The gap above the card, kept when the header pins so it doesn't touch the
                    // top of the scroll view.
                    .padding(.top, PanelMetrics.cardSpacing)
                    .pinnedBackground(edge: .top, isPinned: $isHeaderPinned)
            } footer: {
                if let footer {
                    PanelCardPiece(edge: .bottom) { footer }
                        .pinnedBackground(edge: .bottom, isPinned: $isFooterPinned)
                }
            }
        } else {
            VStack(spacing: 0) {
                header
                content
                footer
            }
            .frame(maxWidth: .infinity)
            .background(Color.appCard)
            .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        }
    }

    private var header: PanelHeader {
        PanelHeader(title: title, subtitle: subtitle, accessory: accessory, favourite: favourite, icon: icon)
    }
}

extension PanelCard where Footer == Never {
    init(title: String, subtitle: String? = nil, accessory: PanelHeader.Accessory? = nil,
         favourite: PanelHeader.Favourite? = nil, icon: String = "bus.fill", @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: accessory, favourite: favourite, icon: icon, footer: nil, content: content)
    }
}

/// A slice of a card in a `PanelCardStack`: the card's background and shadow, with the card's
/// rounded corners on `edge` (if any). The shadow is cut off where the slice meets the next
/// one, so the slices look like one card.
private struct PanelCardPiece<Content: View>: View {
    let edge: VerticalEdge?
    @ViewBuilder let content: Content

    var body: some View {
        let radius = PanelMetrics.cornerRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: edge == .top ? radius : 0,
            bottomLeadingRadius: edge == .bottom ? radius : 0,
            bottomTrailingRadius: edge == .bottom ? radius : 0,
            topTrailingRadius: edge == .top ? radius : 0,
            style: .continuous
        )
        let shadowRoom = PanelMetrics.shadowRadius * 3
        content
            .frame(maxWidth: .infinity)
            .background(Color.appCard)
            .clipShape(shape)
            .background {
                shape
                    .fill(Color.appCard)
                    .shadow(color: PanelMetrics.shadowColor, radius: PanelMetrics.shadowRadius, y: PanelMetrics.shadowOffset)
                    .mask {
                        Rectangle()
                            .padding(.horizontal, -shadowRoom)
                            .padding(.top, edge == .top ? -shadowRoom : 0)
                            .padding(.bottom, edge == .bottom ? -shadowRoom : 0)
                    }
            }
    }
}

private extension View {
    /// While this header (`.top`) or footer (`.bottom`) is pinned, the screen's background behind
    /// it, so the card scrolling under it is hidden around its rounded corners, beside it (with
    /// its shadow) and beyond it, including behind the translucent bars. Not drawn otherwise, so it doesn't cover the
    /// shadow of the card before.
    func pinnedBackground(edge: VerticalEdge, isPinned: Binding<Bool>) -> some View {
        let room = PanelMetrics.shadowRadius * 3
        return background {
            if isPinned.wrappedValue {
                Color.appBackground
                    .padding(.horizontal, -room)
                    // Over what has scrolled past: under the bars above a header, and below a footer.
                    .padding(edge == .top ? .top : .bottom, -PanelMetrics.pinnedCover)
            }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            // The scroll view's visible area, in this view's coordinates.
            guard let visible = proxy.bounds(of: .scrollView(axis: .vertical)) else { return false }
            let tolerance = 0.5
            return switch edge {
            case .top: visible.minY >= -tolerance
            case .bottom: visible.maxY <= proxy.size.height + tolerance
            }
        } action: { isPinned.wrappedValue = $0 }
    }
}

/// A scroll view's column of `PanelCard`s, whose headers and footers pin like a list's section
/// headers and footers. Each card brings its own `PanelMetrics.cardSpacing` above it.
struct PanelCardStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders, .sectionFooters]) {
            content
        }
        .environment(\.panelCardPins, true)
    }
}

extension EnvironmentValues {
    /// Whether `PanelCard`s are sections of a `PanelCardStack`.
    @Entry var panelCardPins = false
    /// Whether the screen is shown above the tab bar (and not in a sheet over it).
    @Entry var isAboveTabBar = false
}

extension View {
    /// For a scroll view holding a `PanelCardStack`: above the tab bar, pinned footers stop a
    /// little short of it, rather than touching it.
    func panelCardScrollView() -> some View {
        modifier(PanelCardScrollView())
    }
}

private struct PanelCardScrollView: ViewModifier {
    @Environment(\.isAboveTabBar) private var isAboveTabBar

    func body(content: Content) -> some View {
        content.safeAreaPadding(.bottom, isAboveTabBar ? PanelMetrics.tabBarFooterGap : 0)
    }
}

enum PanelMetrics {
    static let cornerRadius: CGFloat = 24
    static let horizontalPadding: CGFloat = 16
    /// The space above each card in a `PanelCardStack`, kept above a pinned header.
    static let cardSpacing: CGFloat = 16
    static let shadowColor = Color.black.opacity(0.12)
    static let shadowRadius: CGFloat = 10
    static let shadowOffset: CGFloat = 3
    /// How far above a pinned header and below a pinned footer the background reaches, to
    /// cover what's behind the bars.
    static let pinnedCover: CGFloat = 300
    /// The space between a pinned footer and the tab bar, like the home indicator's margin
    /// when there's no tab bar.
    static let tabBarFooterGap: CGFloat = 16
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
