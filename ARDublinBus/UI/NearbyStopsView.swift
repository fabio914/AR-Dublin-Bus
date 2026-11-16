import CoreLocation
import Observation
import SwiftUI

@MainActor
@Observable
final class NearbyStopsModel {
    enum Phase: Equatable {
        case locating
        case loading
        case loaded
        case failed(String)
        case locationDenied
    }

    struct StopEntry: Identifiable, Equatable {
        let stop: NearbyStop
        var board: StopBoard?
        var id: String { stop.id }
    }

    private(set) var phase: Phase = .locating
    private(set) var stops: [StopEntry] = []
    private(set) var departures: [NearbyDeparture] = []
    private(set) var updatedAt: Date?

    @ObservationIgnored private let service: DepartureService
    @ObservationIgnored private let locationProvider = LocationProvider()

    /// How long to keep refreshing the boards before the location is considered stale.
    static let refreshInterval: Duration = .seconds(30)

    init(service: DepartureService) {
        self.service = service
    }

    /// Finds the user, then keeps the nearby boards fresh until cancelled.
    func run() async {
        phase = .locating
        stops = []
        departures = []

        let nearby: [NearbyStop]
        do {
            let location = try await locationProvider.currentLocation()
            phase = .loading
            nearby = try await service.nearbyStops(around: location.coordinate)
        } catch LocationError.denied {
            phase = .locationDenied
            return
        } catch {
            if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            return
        }
        stops = nearby.map { StopEntry(stop: $0) }

        while !Task.isCancelled {
            do {
                let boards = try await service.boards(forStopCodes: nearby.map(\.stop.code))
                guard !Task.isCancelled else { return }
                stops = zip(nearby, boards).map { StopEntry(stop: $0, board: $1) }
                departures = NearbyDepartures.merge(Array(zip(nearby, boards)).map { (stop: $0, board: $1) })
                updatedAt = boards.first?.updatedAt ?? .now
                phase = .loaded
            } catch {
                if !Task.isCancelled, updatedAt == nil { phase = .failed(error.localizedDescription) }
            }
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    /// Why live data is missing, if it is (the same for every board).
    var realtimeIssue: String? {
        stops.lazy.compactMap(\.board).first?.realtimeIssue
    }
}

/// Stops near the user, each with its next buses, plus one merged list of buses nearby.
struct NearbyStopsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var model: NearbyStopsModel?
    @State private var mode = Mode.stops
    @State private var runID = UUID()

    enum Mode: String, CaseIterable {
        case stops = "Stops"
        case departures = "Next buses"
    }

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        runID = UUID()
                    } label: {
                        Label("Update location", systemImage: "location.circle")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: NearbyStop.self) { stop in
                ScrollView {
                    StopBoardView(stopCode: stop.stop.code)
                        .padding()
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Stop \(stop.stop.code)")
                .navigationBarTitleDisplayMode(.inline)
            }
            .tripDestination()
        }
        .task(id: runID) {
            let model = self.model ?? NearbyStopsModel(service: appModel.service)
            self.model = model
            await model.run()
        }
    }

    @ViewBuilder
    private func content(_ model: NearbyStopsModel) -> some View {
        switch model.phase {
        case .locating:
            ProgressView("Finding your location…")
        case .loading where model.stops.isEmpty:
            ProgressView("Finding stops near you…")
        case .locationDenied:
            ContentUnavailableView {
                Label("Location is off", systemImage: "location.slash")
            } description: {
                Text(LocationError.denied.localizedDescription)
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                .tint(TFIColors.green)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load nearby stops", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { runID = UUID() }
                    .buttonStyle(.borderedProminent)
                    .tint(TFIColors.green)
            }
        case .loading, .loaded:
            list(model)
        }
    }

    private func list(_ model: NearbyStopsModel) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Show", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)

                if let nearest = model.stops.first, nearest.stop.distance > DepartureService.nearbyRadius {
                    Label("No stops within walking distance. These are the closest.", systemImage: "figure.walk")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                switch mode {
                case .stops:
                    if let updatedAt = model.updatedAt {
                        HStack(spacing: 6) {
                            RealtimeStatusLabel(issue: model.realtimeIssue, updatedAt: updatedAt)
                            Spacer(minLength: 0)
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    ForEach(model.stops) { entry in
                        NearbyStopCard(entry: entry)
                    }
                case .departures:
                    NearbyDeparturesCard(model: model)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { runID = UUID() }
    }
}

/// One nearby stop: green header with its distance, the next few buses, and a link to the full board.
private struct NearbyStopCard: View {
    let entry: NearbyStopsModel.StopEntry
    static let rows = 3

    var body: some View {
        PanelCard(
            title: entry.stop.stop.name,
            subtitle: "Stop \(entry.stop.stop.code)",
            accessory: .init(systemImage: "figure.walk", text: DistanceText.walking(entry.stop.distance))
        ) {
            if let board = entry.board {
                let next = Array(board.departures.prefix(Self.rows))
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

            NavigationLink(value: entry.stop) {
                HStack {
                    Text("All departures")
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TFIColors.green)
                .padding(.horizontal, PanelMetrics.horizontalPadding)
                .padding(.vertical, 12)
                .background(PanelMetrics.footerBackground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

/// Every bus leaving the nearby stops, soonest first, with the stop it leaves from.
private struct NearbyDeparturesCard: View {
    let model: NearbyStopsModel

    var body: some View {
        PanelCard(title: "Next buses", subtitle: "From \(model.stops.count) stops near you", icon: "location.fill") {
            if model.departures.isEmpty {
                if model.phase == .loaded {
                    PanelMessage(icon: "moon.zzz.fill", title: "No buses in the next 90 minutes")
                } else {
                    ProgressView().padding(.vertical, 24)
                }
            }
            ForEach(Array(model.departures.enumerated()), id: \.element.id) { index, item in
                if index > 0 { PanelSeparator() }
                let row = DepartureRow(
                    departure: item.departure,
                    now: .now,
                    detail: "\(DistanceText.walking(item.stop.distance)) · Stop \(item.stop.stop.code) · \(item.stop.stop.name)",
                    showsChevron: true
                )
                .contentShape(Rectangle())
                // Opens the bus's line; buses added by the live feed have none, so open their stop.
                Group {
                    if let trip = item.departure.trip {
                        NavigationLink(value: trip) { row }
                    } else {
                        NavigationLink(value: item.stop) { row }
                    }
                }
                .buttonStyle(.plain)
            }
            if let updatedAt = model.updatedAt {
                PanelFooter { RealtimeStatusLabel(issue: model.realtimeIssue, updatedAt: updatedAt) }
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}
