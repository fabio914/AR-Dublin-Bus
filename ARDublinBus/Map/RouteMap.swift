import MapKit
import SwiftUI

/// A route's path on a map: its stops as dots, pins where it starts and ends, the stop the
/// user picked, and the buses running it. Used by the trip and line screens, where it's a still
/// picture until expanded (`ExpandableMap`).
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
    /// Can be panned and zoomed, with the location and compass buttons.
    let isInteractive: Bool
    @State private var position: MapCameraPosition

    /// The height the trip and line screens show it at.
    static let height: CGFloat = 200
    /// So the buses' direction arrows stay right when the map is rotated.
    @State private var heading: CLLocationDirection = 0
    /// Ties the location and compass buttons to the map.
    @Namespace private var mapScope

    init(path: [CLLocationCoordinate2D], stops: [Stop], highlighted: GTFSStop?, vehicles: [VehiclePosition], routeKey: String,
         isInteractive: Bool) {
        self.path = path
        self.stops = stops
        self.highlighted = highlighted
        self.vehicles = vehicles
        self.routeKey = routeKey
        self.isInteractive = isInteractive
        _position = State(initialValue: Self.cameraPosition(for: path))
    }

    /// Expanded, the map goes under the bars, while its buttons keep to the safe area (MapKit's
    /// own would go under the status bar and the navigation bar's buttons). As on the stops map,
    /// the location button is at the bottom right and the compass at the top right.
    var body: some View {
        ZStack {
            map
                .ignoresSafeArea(edges: isInteractive ? .all : [])
            if isInteractive {
                MapCompass(scope: mapScope)
                    .padding(MapButtonLayout.inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                MapUserLocationButton(scope: mapScope)
                    .buttonBorderShape(.circle)
                    .padding(MapButtonLayout.inset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .mapScope(mapScope)
    }

    private var map: some View {
        Map(position: $position, interactionModes: isInteractive ? .all : [], scope: mapScope) {
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
        // The buttons are drawn over it instead (`body`).
        .mapControls {}
        // Still, it lets drags through to the scroll view it's in.
        .allowsHitTesting(isInteractive)
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

/// Where the maps' location button goes: in the bottom right corner of the safe area, this far
/// from its edges (the same on the stops map and the expanded route maps).
enum MapButtonLayout {
    static let inset: CGFloat = 16
    /// The location button's size; MapKit's SwiftUI button is this size.
    static let size: CGFloat = 44
}

/// A map shown still, with a button that expands it to the whole screen, where it can be moved
/// around, and a button there to collapse it again. `map` makes the map, interactive or not.
struct ExpandableMap<MapView: View>: View {
    /// The expanded map's title.
    let title: String
    @ViewBuilder let map: (_ isInteractive: Bool) -> MapView
    @State private var isExpanded = false

    var body: some View {
        map(false)
            .overlay(alignment: .topTrailing) {
                Button {
                    isExpanded = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.cardInk)
                        .frame(width: 36, height: 36)
                        .background(.regularMaterial, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel("Expand map")
            }
            .fullScreenCover(isPresented: $isExpanded) {
                NavigationStack {
                    map(true)
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button {
                                    isExpanded = false
                                } label: {
                                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                                }
                                .accessibilityLabel("Collapse map")
                            }
                        }
                }
            }
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
