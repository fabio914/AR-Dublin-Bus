import MapKit
import SwiftUI

extension View {
    /// Lets `NavigationLink(value: TripReference)` rows open a bus's trip, and
    /// `NavigationLink(value: LineReference)` rows open a route's line screen.
    func routeDestinations() -> some View {
        navigationDestination(for: TripReference.self) { TripView(reference: $0) }
            .navigationDestination(for: LineReference.self) { LineView(reference: $0) }
    }
}

/// One bus's line: its route on a map, and every stop with scheduled or live times.
struct TripView: View {
    @Environment(AppModel.self) private var model
    let reference: TripReference
    @State private var journey: TripJourney?
    @State private var error: String?

    static let refreshInterval: Duration = .seconds(30)

    var body: some View {
        Group {
            if let journey {
                VStack(spacing: 0) {
                    TripMap(journey: journey)
                        .frame(height: 260)
                    TripStopsList(journey: journey)
                }
            } else if let error {
                ContentUnavailableView("Couldn't load this bus", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView("Loading the route…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.appBackground)
        .navigationTitle(journey.map { "Route \($0.route.shortName)" } ?? "Route")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reference) {
            while !Task.isCancelled {
                do {
                    let journey = try await model.service.journey(for: reference)
                    if !Task.isCancelled { self.journey = journey }
                } catch {
                    if !Task.isCancelled, journey == nil { self.error = error.localizedDescription }
                }
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }
}

/// The route's path with its stops, where it starts and ends, the stop the bus was picked
/// from, and the bus itself when it reports its position.
private struct TripMap: View {
    let journey: TripJourney

    var body: some View {
        RouteMap(
            path: journey.shape,
            stops: journey.stops.map { RouteMap.Stop(id: $0.sequence, stop: $0.stop, isDimmed: $0.hasPassed) },
            highlighted: journey.origin?.stop,
            vehicles: journey.vehicle.map { [$0] } ?? [],
            routeKey: journey.reference.tripID
        )
        .overlay(alignment: .bottomLeading) {
            if let vehicle = journey.vehicle {
                MapCaption(systemImage: "bus.fill", text: seen(vehicle))
            }
        }
    }

    private func seen(_ vehicle: VehiclePosition) -> Text {
        guard let timestamp = vehicle.timestamp else { return Text("Live bus position") }
        return Text("Bus seen at \(ETAText.clock(timestamp))")
    }
}

/// Every stop of the trip as a timeline, scrolled to the stop the bus was picked from.
private struct TripStopsList: View {
    let journey: TripJourney

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                PanelCardStack {
                    PanelCard(title: "To \(journey.headsign)", subtitle: subtitle, icon: "bus.fill", footer: footer) {
                        if journey.isCancelled {
                            PanelMessage(icon: "xmark.octagon.fill", title: "This bus is cancelled")
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(journey.stops.enumerated()), id: \.element.id) { index, stop in
                                TripStopRow(
                                    stop: stop,
                                    isOrigin: stop.sequence == journey.reference.stopSequence,
                                    isFirst: index == 0,
                                    isLast: index == journey.stops.count - 1
                                )
                                .id(stop.id)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding([.horizontal, .bottom], 16)
            }
            .onAppear {
                if let origin = journey.origin {
                    proxy.scrollTo(origin.id, anchor: .center)
                }
            }
        }
    }

    private var subtitle: String {
        let count = journey.stops.count
        return "Route \(journey.route.shortName) · \(count) stop\(count == 1 ? "" : "s")"
    }
    private var footer: PanelFooter<RealtimeStatusLabel> {
        PanelFooter { RealtimeStatusLabel(issue: journey.realtimeIssue, updatedAt: journey.updatedAt) }
    }
}

private struct TripStopRow: View {
    let stop: TripJourney.Stop
    let isOrigin: Bool
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Grey where the bus has already been.
            RouteTimelineMarker(isHighlighted: isOrigin, isDimmed: stop.hasPassed, isFirst: isFirst, isLast: isLast)
            VStack(alignment: .leading, spacing: 1) {
                Text(stop.stop.name)
                    .font(.system(size: 16, weight: isOrigin ? .bold : .medium))
                    .foregroundStyle(stop.hasPassed ? Color.cardSecondaryInk : Color.cardInk)
                    .strikethrough(stop.isCancelled)
                    .lineLimit(2)
                Text("Stop \(stop.stop.code)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.cardSecondaryInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            time
        }
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .background(isOrigin ? TFIColors.yellow.opacity(0.22) : .clear)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var time: some View {
        if stop.isCancelled {
            Text("Cancelled")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.red)
        } else {
            HStack(spacing: 4) {
                if stop.isRealtime && !stop.hasPassed {
                    Image(systemName: "dot.radiowaves.up.forward")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.cardLive)
                }
                Text(ETAText.clock(stop.expected))
                    .font(.system(size: 15, weight: stop.isRealtime ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(stop.hasPassed || !stop.isRealtime ? Color.cardSecondaryInk : Color.cardInk)
                    .monospacedDigit()
            }
        }
    }
}

/// A stop on a vertical line through every stop of a route, as on the trip and line screens.
struct RouteTimelineMarker: View {
    /// The stop the user picked: a bigger, yellow dot.
    let isHighlighted: Bool
    /// Grey, e.g. the bus has already been there.
    let isDimmed: Bool
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        let colour = isDimmed ? Color.gray.opacity(0.5) : Color.appTint
        ZStack {
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? .clear : colour).frame(width: 4)
                Rectangle().fill(isLast ? .clear : colour).frame(width: 4)
            }
            Circle()
                .fill(isHighlighted ? TFIColors.yellow : .white)
                .stroke(colour, lineWidth: 3)
                .frame(width: isHighlighted ? 18 : 13, height: isHighlighted ? 18 : 13)
        }
        .frame(width: 20)
    }
}
