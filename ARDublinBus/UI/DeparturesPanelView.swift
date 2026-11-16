import SwiftUI

enum TFIColors {
    static let green = Color(red: 0 / 255, green: 102 / 255, blue: 84 / 255)
    static let darkGreen = Color(red: 0 / 255, green: 74 / 255, blue: 61 / 255)
    static let yellow = Color(red: 255 / 255, green: 210 / 255, blue: 0 / 255)
    static let live = Color(red: 0 / 255, green: 150 / 255, blue: 95 / 255)
    static let ink = Color(red: 0.11, green: 0.12, blue: 0.13)
    static let secondaryInk = Color(red: 0.38, green: 0.4, blue: 0.42)
    static let separator = Color(red: 0.88, green: 0.89, blue: 0.9)
}

/// The floating departures board. Rendered into a texture for the AR panel and
/// also shown directly in the manual stop lookup sheet.
struct DeparturesPanelView: View {
    let content: PanelContent
    let now: Date
    var maximumRows = 6
    /// Rows open the bus's line when tapped (inside a `NavigationStack` using `tripDestination()`).
    var linksToTrips = false

    static let width: CGFloat = 360

    var body: some View {
        PanelCard(title: stopTitle, subtitle: stopName) {
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
        .frame(width: Self.width)
    }

    private var stopTitle: String {
        switch content {
        case .reading: "Bus stop"
        case .loading(let code): "Stop \(code)"
        case .failure(let code, _): code.map { "Stop \($0)" } ?? "Bus stop"
        case .board(let board): "Stop \(board.stopCode)"
        }
    }

    private var stopName: String? {
        if case .board(let board) = content, !board.stopName.isEmpty { return board.stopName }
        return nil
    }

    // MARK: Board

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
            PanelFooter { RealtimeStatusLabel(issue: board.realtimeIssue, updatedAt: board.updatedAt) }
        }
    }

    static let clockFormat = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: Dublin.timeZone)
}

/// "Live · updated 18:54", or why only timetable times are shown.
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
                .foregroundStyle(TFIColors.live)
            Text("Live · updated \(updatedAt.formatted(DeparturesPanelView.clockFormat))")
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
                    .foregroundStyle(departure.isCancelled ? TFIColors.secondaryInk : TFIColors.ink)
                    .strikethrough(departure.isCancelled)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(TFIColors.secondaryInk)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            eta

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TFIColors.secondaryInk.opacity(0.7))
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
                    .foregroundStyle(TFIColors.live)
                Text(ETAText.relative(departure, now: now))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(TFIColors.ink)
                    .monospacedDigit()
            }
        } else {
            Text(ETAText.clock(departure.expected))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(TFIColors.secondaryInk)
                .monospacedDigit()
        }
    }
}

enum ETAText {
    /// "Due", "7 min", or a clock time when an hour or more away.
    static func relative(_ departure: Departure, now: Date) -> String {
        let minutes = departure.minutesAway(from: now)
        if minutes <= 0 { return "Due" }
        if minutes < 60 { return "\(minutes) min" }
        return clock(departure.expected)
    }

    static func clock(_ date: Date) -> String {
        date.formatted(DeparturesPanelView.clockFormat)
    }
}
