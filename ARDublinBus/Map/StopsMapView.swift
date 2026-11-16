import MapKit
import Observation
import SwiftUI

extension GTFSStop: Identifiable {}

/// Loads the stops inside the visible part of the map.
@MainActor
@Observable
final class StopsMapModel {
    private(set) var stops: [GTFSStop] = []
    /// Why no (or not all) stops are shown, if that's the case.
    private(set) var hint: String?

    @ObservationIgnored private let service: DepartureService
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// Above this latitude span (about 30 km), the map shows no stops.
    static let maximumSpan: CLLocationDegrees = 0.3
    static let maximumStops = 2500

    init(service: DepartureService) {
        self.service = service
    }

    func visibleAreaChanged(_ region: MKCoordinateRegion) {
        loadTask?.cancel()
        guard region.span.latitudeDelta <= Self.maximumSpan else {
            stops = []
            hint = "Zoom in to see bus stops"
            return
        }

        // Load a margin around the visible area so small pans don't need a reload.
        let bounds = CoordinateBounds(
            minLatitude: region.center.latitude - region.span.latitudeDelta * 0.75,
            maxLatitude: region.center.latitude + region.span.latitudeDelta * 0.75,
            minLongitude: region.center.longitude - region.span.longitudeDelta * 0.75,
            maxLongitude: region.center.longitude + region.span.longitudeDelta * 0.75
        )
        loadTask = Task {
            // Wait for the map to settle.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            do {
                let result = try await service.stops(in: bounds, limit: Self.maximumStops)
                guard !Task.isCancelled else { return }
                stops = result.stops
                hint = result.isTruncated ? "Zoom in to see all bus stops" : nil
            } catch {
                guard !Task.isCancelled else { return }
                hint = error.localizedDescription
            }
        }
    }
}

/// Every bus stop on a map. Tapping a stop shows its board; tapping a bus there shows its line.
struct StopsMapView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var model: StopsMapModel?
    @State private var selectedStop: GTFSStop?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if let model {
                    ClusteredStopsMap(
                        stops: model.stops,
                        selectedStopID: selectedStop?.id,
                        onVisibleAreaChange: { model.visibleAreaChanged($0) },
                        onSelectStop: { selectedStop = $0 }
                    )
                    .ignoresSafeArea(edges: .bottom)

                    if let hint = model.hint {
                        Text(hint)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.top, 8)
                    }
                }
            }
            .navigationTitle("Bus stops")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if model == nil { model = StopsMapModel(service: appModel.service) }
        }
        .sheet(item: $selectedStop) { stop in
            StopBoardSheet(stop: stop) { selectedStop = nil }
        }
    }
}
