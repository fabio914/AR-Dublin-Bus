import SwiftUI

/// The floating departures board. Rendered into a texture for the AR panel and
/// also shown directly in the manual stop lookup sheet.
struct DeparturesPanelView: View {
    let content: PanelContent
    let now: Date
    var maximumRows = 6
    /// Rows open the bus's line when tapped (inside a `NavigationStack` using `routeDestinations()`).
    var linksToTrips = false
    /// A star in the header for starring the stop (in-app boards only).
    var favourite: PanelHeader.Favourite?

    /// The AR panel's width. In the app, the board is as wide as the other cards.
    static let width: CGFloat = 360

    var body: some View {
        PanelCard(title: Self.title(for: content), subtitle: Self.stopName(for: content), favourite: favourite, footer: footer) {
            DeparturesPanelBody(content: content, now: now, maximumRows: maximumRows, linksToTrips: linksToTrips, showsFooter: false)
        }
    }

    private var footer: PanelFooter<RealtimeStatusLabel>? {
        guard case .board(let board) = content else { return nil }
        return PanelFooter { RealtimeStatusLabel(issue: board.realtimeIssue, updatedAt: board.updatedAt) }
    }

    static func title(for content: PanelContent) -> String {
        switch content {
        case .reading: "Bus stop"
        case .loading(let code): "Stop \(code)"
        case .failure(let code, _): code.map { "Stop \($0)" } ?? "Bus stop"
        case .board(let board): "Stop \(board.stopCode)"
        }
    }

    static func stopName(for content: PanelContent) -> String? {
        if case .board(let board) = content, !board.stopName.isEmpty { return board.stopName }
        return nil
    }
}

/// Everything under the board's header: the departures, or a message. It has no background of
/// its own (the card provides it), so the AR card can draw it as a separate layer.
struct DeparturesPanelBody: View {
    let content: PanelContent
    let now: Date
    var maximumRows = 6
    var linksToTrips = false
    /// The live/timetable strip under a board; off when the card shows it as its footer.
    var showsFooter = true

    var body: some View {
        switch content {
        case .reading(let hint):
            PanelMessage(icon: "text.viewfinder", title: "Reading stop number…", detail: hint)
        case .loading:
            PanelMessage(icon: "clock.arrow.circlepath", title: "Loading departures…")
        case .failure(_, let error):
            PanelMessage(icon: "exclamationmark.triangle.fill", title: "Couldn't load departures", detail: error)
        case .board(let board):
            boardBody(board)
        }
    }

    @ViewBuilder
    private func boardBody(_ board: StopBoard) -> some View {
        let departures = Array(board.departures.prefix(maximumRows))
        VStack(spacing: 0) {
            if departures.isEmpty {
                PanelMessage(icon: "moon.zzz.fill", title: "No departures in the next 90 minutes")
            } else {
                ForEach(Array(departures.enumerated()), id: \.element.id) { index, departure in
                    if index > 0 { PanelSeparator() }
                    if linksToTrips, let trip = departure.trip {
                        NavigationLink(value: trip) {
                            DepartureRow(departure: departure, now: now, showsChevron: true)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        DepartureRow(departure: departure, now: now)
                    }
                }
            }
            if showsFooter {
                PanelFooter { RealtimeStatusLabel(issue: board.realtimeIssue, updatedAt: board.updatedAt) }
            }
        }
    }
}

extension PanelContent {
    /// The stop this content is about, if it's known.
    var stopCode: String? {
        switch self {
        case .reading: nil
        case .loading(let code): code
        case .failure(let code, _): code
        case .board(let board): board.stopCode
        }
    }
}

struct RealtimeStatusLabel: View {
    let issue: String?
    let updatedAt: Date

    var body: some View {
        if let issue {
            Image(systemName: "calendar")
            Text("Timetable only · \(issue)")
                .lineLimit(2)
        } else {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color.cardLive)
            Text("Live · updated \(updatedAt.formatted(ETAText.clockFormat))")
        }
    }
}

/// One bus: route badge, destination (and optional detail line), and ETA.
struct DepartureRow: View {
    let departure: Departure
    let now: Date
    var detail: String?
    /// Shows that the row can be tapped.
    var showsChevron = false

    var body: some View {
        HStack(spacing: 12) {
            Text(departure.route)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(TFIColors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 56, height: 34)
                .background(TFIColors.yellow, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(departure.destination.isEmpty ? " " : departure.destination)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(departure.isCancelled ? Color.cardSecondaryInk : Color.cardInk)
                    .strikethrough(departure.isCancelled)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.cardSecondaryInk)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            eta

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.cardSecondaryInk.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var eta: some View {
        if departure.isCancelled {
            Text("Cancelled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.red)
        } else if departure.isRealtime {
            HStack(spacing: 4) {
                Image(systemName: "dot.radiowaves.up.forward")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.cardLive)
                Text(ETAText.relative(departure, now: now))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.cardInk)
                    .monospacedDigit()
            }
        } else {
            Text(ETAText.clock(departure.expected))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cardSecondaryInk)
                .monospacedDigit()
        }
    }
}

extension ETAText {
    static func relative(_ departure: Departure, now: Date) -> String {
        relative(expected: departure.expected, now: now)
    }
}
