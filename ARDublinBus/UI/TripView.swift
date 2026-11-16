import MapKit
import SwiftUI

extension View {
    /// Lets `NavigationLink(value: TripReference)` rows open the line screen.
    func tripDestination() -> some View {
        navigationDestination(for: TripReference.self) { TripView(reference: $0) }
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
        .background(Color(.systemGroupedBackground))
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

/// The route's path with its stops; the stop the bus was picked from is highlighted.
private struct TripMap: View {
    let journey: TripJourney
    @State private var position: MapCameraPosition

    init(journey: TripJourney) {
        self.journey = journey
        _position = State(initialValue: Self.cameraPosition(for: journey))
    }

    var body: some View {
        Map(position: $position) {
            MapPolyline(coordinates: journey.shape)
                .stroke(TFIColors.green, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))

            ForEach(journey.stops) { stop in
                if let coordinate = stop.stop.coordinate {
                    if stop.sequence == journey.reference.stopSequence {
                        Annotation(stop.stop.name, coordinate: coordinate) {
                            Image(systemName: "bus.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(TFIColors.ink)
                                .frame(width: 28, height: 28)
                                .background(TFIColors.yellow, in: Circle())
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                                .shadow(radius: 2)
                        }
                    } else {
                        Annotation(stop.stop.name, coordinate: coordinate) {
                            Circle()
                                .fill(.white)
                                .stroke(stop.hasPassed ? Color.gray : TFIColors.darkGreen, lineWidth: 2)
                                .frame(width: 7, height: 7)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }

            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
    }

    /// The whole route, with some padding.
    static func cameraPosition(for journey: TripJourney) -> MapCameraPosition {
        guard !journey.shape.isEmpty else { return .automatic }
        var rect = MKPolyline(coordinates: journey.shape, count: journey.shape.count).boundingMapRect
        let padding = max(rect.width, rect.height) * 0.12 + 300
        rect = rect.insetBy(dx: -padding, dy: -padding)
        return .rect(rect)
    }
}

/// Every stop of the trip as a timeline, scrolled to the stop the bus was picked from.
private struct TripStopsList: View {
    let journey: TripJourney

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                PanelCard(title: "To \(journey.headsign)", subtitle: subtitle, icon: "bus.fill") {
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
                    PanelFooter { RealtimeStatusLabel(issue: journey.realtimeIssue, updatedAt: journey.updatedAt) }
                }
                .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                .padding(16)
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
}

private struct TripStopRow: View {
    let stop: TripJourney.Stop
    let isOrigin: Bool
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(spacing: 12) {
            timeline
            VStack(alignment: .leading, spacing: 1) {
                Text(stop.stop.name)
                    .font(.system(size: 16, weight: isOrigin ? .bold : .medium))
                    .foregroundStyle(stop.hasPassed ? TFIColors.secondaryInk : TFIColors.ink)
                    .strikethrough(stop.isCancelled)
                    .lineLimit(2)
                Text("Stop \(stop.stop.code)")
                    .font(.system(size: 13))
                    .foregroundStyle(TFIColors.secondaryInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            time
        }
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .background(isOrigin ? TFIColors.yellow.opacity(0.22) : .clear)
        .accessibilityElement(children: .combine)
    }

    /// A vertical line through every stop, grey where the bus has already been.
    private var timeline: some View {
        let colour = stop.hasPassed ? Color.gray.opacity(0.5) : TFIColors.green
        return ZStack {
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? .clear : colour).frame(width: 4)
                Rectangle().fill(isLast ? .clear : colour).frame(width: 4)
            }
            Circle()
                .fill(isOrigin ? TFIColors.yellow : .white)
                .stroke(colour, lineWidth: 3)
                .frame(width: isOrigin ? 18 : 13, height: isOrigin ? 18 : 13)
        }
        .frame(width: 20)
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
                        .foregroundStyle(TFIColors.live)
                }
                Text(ETAText.clock(stop.expected))
                    .font(.system(size: 15, weight: stop.isRealtime ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(stop.hasPassed || !stop.isRealtime ? TFIColors.secondaryInk : TFIColors.ink)
                    .monospacedDigit()
            }
        }
    }
}
