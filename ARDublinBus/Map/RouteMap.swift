import MapKit
import SwiftUI

/// A route's path on a map: its stops as dots, pins where it starts and ends, the stop the
/// user picked, and the buses running it. Used by the trip and line screens.
struct RouteMap: View {
    struct Stop: Identifiable {
        let id: Int
        let stop: GTFSStop
        /// Drawn in grey, e.g. the bus has already passed it.
        var isDimmed = false
    }

    let path: [CLLocationCoordinate2D]
    let stops: [Stop]
    /// The stop the user picked the bus or line from.
    let highlighted: GTFSStop?
    let vehicles: [VehiclePosition]
    /// The camera goes back to the whole route when this changes (e.g. another direction).
    let routeKey: String
    @State private var position: MapCameraPosition
    /// So the buses' direction arrows stay right when the map is rotated.
    @State private var heading: CLLocationDirection = 0

    init(path: [CLLocationCoordinate2D], stops: [Stop], highlighted: GTFSStop?, vehicles: [VehiclePosition], routeKey: String) {
        self.path = path
        self.stops = stops
        self.highlighted = highlighted
        self.vehicles = vehicles
        self.routeKey = routeKey
        _position = State(initialValue: Self.cameraPosition(for: path))
    }

    var body: some View {
        Map(position: $position) {
            MapPolyline(coordinates: path)
                .stroke(Color.appTint, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))

            // Drawn on the map rather than as annotations, so they don't hide the path when
            // zoomed out: they shrink to ticks along it, and grow as the map zooms in.
            ForEach(stops) { stop in
                if stop.stop.id != highlighted?.id, let coordinate = stop.stop.coordinate {
                    MapCircle(center: coordinate, radius: Self.stopRadius)
                        .foregroundStyle(.white)
                        .stroke(stop.isDimmed ? Color.gray : TFIColors.darkGreen, lineWidth: 2)
                }
            }

            // The ends, unless the user's stop is one of them (its own pin says enough).
            if let start = stops.first?.stop, start.id != highlighted?.id, let coordinate = start.coordinate {
                Marker("Start · \(start.name)", systemImage: "flag.fill", coordinate: coordinate)
                    .tint(TFIColors.green)
            }
            if stops.count > 1, let end = stops.last?.stop, end.id != highlighted?.id, let coordinate = end.coordinate {
                Marker("End · \(end.name)", systemImage: "flag.checkered", coordinate: coordinate)
                    .tint(TFIColors.ink)
            }

            if let highlighted, let coordinate = highlighted.coordinate {
                Annotation(highlighted.name, coordinate: coordinate, anchor: .center) {
                    YourStopMarker()
                }
            }

            ForEach(vehicles) { vehicle in
                Annotation("Bus", coordinate: CLLocationCoordinate2D(latitude: vehicle.latitude, longitude: vehicle.longitude), anchor: .center) {
                    LiveBusMarker(bearing: vehicle.bearing.map { $0 - heading })
                }
                .annotationTitles(.hidden)
            }

            UserAnnotation()
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            heading = context.camera.heading
        }
        .onChange(of: routeKey) {
            withAnimation { position = Self.cameraPosition(for: path) }
        }
    }

    /// Metres.
    static let stopRadius: CLLocationDistance = 12

    /// The whole route, with some padding.
    static func cameraPosition(for path: [CLLocationCoordinate2D]) -> MapCameraPosition {
        guard !path.isEmpty else { return .automatic }
        var rect = MKPolyline(coordinates: path, count: path.count).boundingMapRect
        let padding = max(rect.width, rect.height) * 0.12 + 300
        rect = rect.insetBy(dx: -padding, dy: -padding)
        return .rect(rect)
    }
}

/// The stop the user picked: someone waiting, so it isn't mistaken for the bus.
struct YourStopMarker: View {
    var body: some View {
        Image(systemName: "figure.stand")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(TFIColors.darkGreen)
            .frame(width: 28, height: 28)
            .background(.white, in: Circle())
            .overlay(Circle().stroke(TFIColors.darkGreen, lineWidth: 2.5))
            .shadow(radius: 2)
            .accessibilityLabel("Your stop")
    }
}

/// A bus where it last reported itself, with an arrow for the way it's heading.
struct LiveBusMarker: View {
    /// Degrees clockwise from the top of the screen.
    let bearing: Double?

    var body: some View {
        ZStack {
            if let bearing {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(TFIColors.darkGreen)
                    .offset(y: -21)
                    .rotationEffect(.degrees(bearing))
            }
            Image(systemName: "bus.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(TFIColors.ink)
                .frame(width: 30, height: 30)
                .background(TFIColors.yellow, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(radius: 2)
        }
        .frame(width: 52, height: 52)
        .accessibilityElement()
        .accessibilityLabel("Bus, live position")
    }
}

/// A small label over the bottom of a route map.
struct MapCaption: View {
    let systemImage: String
    let text: Text

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            text
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.cardInk)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(10)
    }
}
