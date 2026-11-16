import SwiftUI

/// One stop: green header with a star, its next few buses, and a link to the full board.
/// Use inside a `NavigationStack` with `tripDestination()` and a destination for `Destination`.
struct StopSummaryCard<Destination: Hashable>: View {
    @Environment(AppModel.self) private var model
    let code: String
    let name: String
    var accessory: PanelHeader.Accessory?
    /// `nil` while loading.
    let board: StopBoard?
    /// Shown instead of the buses when the stop has no board.
    var unavailable: String?
    /// Pushed by "All departures".
    let destination: Destination
    var rows = 3

    var body: some View {
        PanelCard(
            title: name.isEmpty ? "Stop \(code)" : name,
            subtitle: name.isEmpty ? nil : "Stop \(code)",
            accessory: accessory,
            favourite: favourite
        ) {
            if let unavailable {
                PanelMessage(icon: "exclamationmark.triangle.fill", title: "No departures", detail: unavailable)
            } else if let board {
                let next = Array(board.departures.prefix(rows))
                if next.isEmpty {
                    PanelMessage(icon: "moon.zzz.fill", title: "No departures in the next 90 minutes")
                }
                ForEach(Array(next.enumerated()), id: \.element.id) { index, departure in
                    if index > 0 { PanelSeparator() }
                    if let trip = departure.trip {
                        NavigationLink(value: trip) {
                            DepartureRow(departure: departure, now: .now, showsChevron: true)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        DepartureRow(departure: departure, now: .now)
                    }
                }
            } else {
                ProgressView()
                    .padding(.vertical, 24)
            }

            NavigationLink(value: destination) {
                HStack {
                    Text("All departures")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.appTint)
                .padding(.horizontal, PanelMetrics.horizontalPadding)
                .padding(.vertical, 12)
                .background(PanelMetrics.footerBackground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    private var favourite: PanelHeader.Favourite {
        let favourites = model.favourites
        return .init(isOn: favourites.contains(code)) { [code, name] in
            withAnimation { favourites.toggle(code: code, name: name) }
        }
    }
}
