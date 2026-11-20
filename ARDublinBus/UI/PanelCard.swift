import SwiftUI

/// The card style shared by the AR panel and the in-app boards: a TFI-green header over a
/// card body, and an optional footer. The body follows light and dark mode (see the `card…`
/// colours); the AR panel is rendered in light mode.
///
/// Inside a `PanelCardStack` the card is a `Section`, so its header and footer pin to the
/// scroll view's edges while the body scrolls under them. Anywhere else it's drawn whole.
/// Either way, don't apply modifiers to it: in a stack they'd apply to each part separately.
struct PanelCard<Content: View, Footer: View, Banner: View>: View {
    let title: String
    var subtitle: String?
    var accessory: PanelHeader.Accessory?
    var favourite: PanelHeader.Favourite?
    var icon = "bus.fill"
    /// A button on the right of the header with a menu, e.g. for picking a route's destination.
    var optionsMenu: PanelHeader.OptionsMenu?
    /// Shown under the green title bar as part of the header, so it pins with it (e.g. a map).
    let banner: Banner?
    let footer: Footer?
    let content: Content

    @Environment(\.panelCardPins) private var pins
    /// The header with the gap above it, and the footer, for clipping the body under them.
    @State private var headerHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    init(title: String, subtitle: String? = nil, accessory: PanelHeader.Accessory? = nil,
         favourite: PanelHeader.Favourite? = nil, icon: String = "bus.fill", optionsMenu: PanelHeader.OptionsMenu? = nil,
         banner: Banner?, footer: Footer?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.favourite = favourite
        self.icon = icon
        self.optionsMenu = optionsMenu
        self.banner = banner
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        if pins {
            Section {
                PanelCardPiece(edge: footer == nil ? .bottom : nil) {
                    content
                }
                .clippedUnderPinnedViews(headerHeight: headerHeight, footerHeight: footer == nil ? 0 : footerHeight)
            } header: {
                PanelCardPiece(edge: .top) {
                    VStack(spacing: 0) {
                        header
                        banner
                    }
                }
                    // The gap above the card, kept when the header pins so it doesn't touch the
                    // top of the scroll view.
                    .padding(.top, PanelMetrics.cardSpacing)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            } footer: {
                if let footer {
                    PanelCardPiece(edge: .bottom) { footer }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                }
            }
        } else {
            VStack(spacing: 0) {
                header
                banner
                content
                footer
            }
            .frame(maxWidth: .infinity)
            .background(Color.appCard)
            .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        }
    }

    /// Smaller in the app than on the AR panel, where it's read from a distance.
    private var header: PanelHeader {
        PanelHeader(title: title, subtitle: subtitle, accessory: accessory, favourite: favourite, icon: icon,
                    optionsMenu: optionsMenu, scale: pins ? PanelHeader.inAppScale : 1)
    }
}

extension PanelCard where Banner == Never {
    init(title: String, subtitle: String? = nil, accessory: PanelHeader.Accessory? = nil,
         favourite: PanelHeader.Favourite? = nil, icon: String = "bus.fill", optionsMenu: PanelHeader.OptionsMenu? = nil,
         footer: Footer?, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: accessory, favourite: favourite, icon: icon,
                  optionsMenu: optionsMenu, banner: nil, footer: footer, content: content)
    }
}

extension PanelCard where Footer == Never, Banner == Never {
    init(title: String, subtitle: String? = nil, accessory: PanelHeader.Accessory? = nil,
         favourite: PanelHeader.Favourite? = nil, icon: String = "bus.fill", @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: accessory, favourite: favourite, icon: icon,
                  banner: nil, footer: nil, content: content)
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
    /// Hides a card's body where it has scrolled under its pinned header (and the gap above it)
    /// or footer, so it never shows above the header (or behind the bars) or below the footer.
    /// The cut is hidden by the header or footer, so the body seems to slide under it.
    func clippedUnderPinnedViews(headerHeight: CGFloat, footerHeight: CGFloat) -> some View {
        mask {
            GeometryReader { proxy in
                let size = proxy.size
                // Room for the body's shadow beside it, and below it when it's the card's end.
                let room = PanelMetrics.shadowRadius * 3
                // The scroll view's visible area, in the body's coordinates; whole outside one.
                let visible = proxy.bounds(of: .scrollView(axis: .vertical))
                    ?? CGRect(x: 0, y: -1e6, width: size.width, height: 2e6)
                // Where a pinned header ends and a pinned footer starts; beyond the body when
                // they aren't pinned over it.
                let top = max(visible.minY + headerHeight, -room)
                let bottom = min(visible.maxY - footerHeight, size.height + room)
                Rectangle()
                    .frame(width: size.width + 2 * room, height: max(bottom - top, 0))
                    .position(x: size.width / 2, y: (top + bottom) / 2)
            }
        }
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

    /// A button on the right of the header, where the star goes in other cards, that opens a
    /// menu of choices (e.g. a route's destinations).
    struct OptionsMenu {
        struct Option: Identifiable {
            let id: String
            let title: String
        }

        /// What's being chosen, e.g. "Destination".
        let label: String
        let systemImage: String
        let options: [Option]
        let selectedID: String
        let select: (String) -> Void
    }

    let title: String
    var subtitle: String?
    var accessory: Accessory?
    var favourite: Favourite?
    var icon = "bus.fill"
    var optionsMenu: OptionsMenu?
    /// Scales the header's icons, text and vertical spacing (not its side padding, which lines
    /// it up with the card's rows).
    var scale: CGFloat = 1

    /// The scale of the headers of the in-app cards, 25% smaller than on the AR panel.
    static let inAppScale: CGFloat = 0.75

    /// The size of the buttons on the right: wide enough to tap easily, and no taller than the
    /// icon on the left.
    private var buttonSize: CGSize {
        CGSize(width: 36, height: min(36, 44 * scale))
    }

    var body: some View {
        HStack(spacing: 12 * scale) {
            Image(systemName: icon)
                .font(.system(size: 22 * scale, weight: .semibold))
                .frame(width: 44 * scale, height: 44 * scale)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10 * scale, style: .continuous))
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(title)
                    .font(.system(size: 22 * scale, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 15 * scale, weight: .medium))
                        .opacity(0.85)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let accessory {
                Label(accessory.text, systemImage: accessory.systemImage)
                    .font(.system(size: 14 * scale, weight: .semibold))
                    .padding(.horizontal, 10 * scale)
                    .padding(.vertical, 6 * scale)
                    .background(Color.white.opacity(0.18), in: Capsule())
                    .fixedSize()
            }
            if let favourite {
                Button(action: favourite.toggle) {
                    Image(systemName: favourite.isOn ? "star.fill" : "star")
                        .font(.system(size: 20 * scale, weight: .semibold))
                        .foregroundStyle(favourite.isOn ? TFIColors.yellow : .white)
                        .frame(width: buttonSize.width, height: buttonSize.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(favourite.isOn ? "Remove from favourites" : "Add to favourites")
                .sensoryFeedback(.selection, trigger: favourite.isOn)
            }
            if let optionsMenu {
                Menu {
                    Picker(optionsMenu.label, selection: Binding(get: { optionsMenu.selectedID }, set: optionsMenu.select)) {
                        ForEach(optionsMenu.options) { Text($0.title).tag($0.id) }
                    }
                } label: {
                    Image(systemName: optionsMenu.systemImage)
                        .font(.system(size: 20 * scale, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: buttonSize.width, height: buttonSize.height)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .accessibilityLabel(optionsMenu.label)
                .sensoryFeedback(.selection, trigger: optionsMenu.selectedID)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, 14 * scale)
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
