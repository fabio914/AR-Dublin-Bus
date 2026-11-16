import SwiftUI

/// One page per nearby stop, swiped horizontally.
struct NearbyPagesView: View {
    @Environment(WatchNearbyModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: String?

    var body: some View {
        NavigationStack {
            Group {
                if let response = model.response, !response.stops.isEmpty {
                    TabView(selection: $selection) {
                        ForEach(response.stops) { stop in
                            StopPage(stop: stop, realtimeIssue: response.realtimeIssue, updatedAt: response.generatedAt,
                                     refreshFailure: model.refreshFailure)
                                .tag(Optional(stop.id))
                                .containerBackground(TFIColors.green.gradient, for: .tabView)
                        }
                    }
                    .tabViewStyle(.page)
                } else {
                    StatusView(phase: model.phase)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        if model.phase == .locating || model.phase == .loading {
                            ProgressView()
                        } else {
                            Image(systemName: "location.fill")
                        }
                    }
                    .accessibilityLabel("Refresh nearby stops")
                }
            }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await model.keepFresh()
        }
    }
}

private struct StopPage: View {
    let stop: WatchNearbyResponse.Stop
    let realtimeIssue: String?
    let updatedAt: Date
    /// Set when the boards couldn't be updated: what's shown is getting old.
    let refreshFailure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(stop.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text("Stop \(stop.code) · \(DistanceText.walking(stop.distance))")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                }

                // Buses drop off the list as they leave, even if the phone can't be reached.
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let departures = stop.upcomingDepartures(at: context.date)
                    if departures.isEmpty {
                        Text(refreshFailure == nil ? "No buses in the next 90 minutes" : "No recent times")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                    } else {
                        VStack(spacing: 6) {
                            ForEach(departures) { departure in
                                DepartureRow(departure: departure, now: context.date)
                            }
                        }
                    }
                }

                if let refreshFailure {
                    Label("Not updated since \(updatedAt.formatted(ETAText.clockFormat)). \(refreshFailure)",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(TFIColors.yellow)
                } else {
                    Label(
                        "\(realtimeIssue == nil ? "Live" : "Timetable") · \(updatedAt.formatted(ETAText.clockFormat))",
                        systemImage: realtimeIssue == nil ? "dot.radiowaves.left.and.right" : "calendar"
                    )
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DepartureRow: View {
    let departure: WatchNearbyResponse.Departure
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Text(departure.route)
                .font(.system(.footnote, design: .rounded).weight(.heavy))
                .foregroundStyle(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 38, height: 22)
                .background(TFIColors.yellow, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(departure.destination)
                .font(.footnote)
                .lineLimit(1)
                .strikethrough(departure.isCancelled)
                .opacity(departure.isCancelled ? 0.6 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)

            eta
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var eta: some View {
        if departure.isCancelled {
            Text("Cancelled")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
        } else {
            HStack(spacing: 2) {
                if departure.isRealtime {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(TFIColors.liveOnDark)
                }
                Text(departure.eta(from: now))
                    .font(.system(.footnote, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .opacity(departure.isRealtime ? 1 : 0.75)
            }
            .fixedSize()
        }
    }
}

private struct StatusView: View {
    let phase: WatchNearbyModel.Phase

    var body: some View {
        VStack(spacing: 8) {
            switch phase {
            case .idle, .locating:
                ProgressView()
                Text("Finding your location…")
            case .loading:
                ProgressView()
                Text("Asking your iPhone for nearby stops…")
            case .loaded:
                Image(systemName: "bus")
                    .font(.title2)
                Text("No stops nearby")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(TFIColors.yellow)
                Text(message)
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .padding()
    }
}
