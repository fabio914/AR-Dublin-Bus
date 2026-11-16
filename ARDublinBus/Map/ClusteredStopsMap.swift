import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// An `MKMapView` showing bus stops as clustered pins.
///
/// SwiftUI's `Map` has no clustering, so this wraps MapKit's view. The pins are whatever
/// `stops` contains; the owner reloads them for the visible area via `onVisibleAreaChange`.
struct ClusteredStopsMap: UIViewRepresentable {
    let stops: [GTFSStop]
    /// The stop whose board is showing; cleared when the board is dismissed.
    let selectedStopID: String?
    let onVisibleAreaChange: (MKCoordinateRegion) -> Void
    let onSelectStop: (GTFSStop) -> Void

    /// Dublin city centre, around O'Connell Street.
    static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 53.3498, longitude: -6.2603),
        latitudinalMeters: 1600, longitudinalMeters: 1600
    )

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.setRegion(Self.defaultRegion, animated: false)
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = true
        mapView.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.stopReuseIdentifier)
        mapView.register(MKMarkerAnnotationView.self,
                         forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)

        let trackingButton = MKUserTrackingButton(mapView: mapView)
        trackingButton.translatesAutoresizingMaskIntoConstraints = false
        trackingButton.backgroundColor = .systemBackground
        trackingButton.layer.cornerRadius = 8
        trackingButton.layer.shadowOpacity = 0.15
        trackingButton.layer.shadowRadius = 4
        trackingButton.layer.shadowOffset = CGSize(width: 0, height: 1)
        mapView.addSubview(trackingButton)
        NSLayoutConstraint.activate([
            trackingButton.trailingAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            trackingButton.bottomAnchor.constraint(equalTo: mapView.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])

        context.coordinator.locationManager.requestWhenInUseAuthorization()
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.show(stops, on: mapView)

        if selectedStopID == nil {
            for annotation in mapView.selectedAnnotations where annotation is StopAnnotation {
                mapView.deselectAnnotation(annotation, animated: true)
            }
        }
    }

    final class StopAnnotation: NSObject, MKAnnotation {
        let stop: GTFSStop
        let coordinate: CLLocationCoordinate2D

        init?(stop: GTFSStop) {
            guard let latitude = stop.latitude, let longitude = stop.longitude else { return nil }
            self.stop = stop
            coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        var title: String? { stop.name }
        var subtitle: String? { "Stop \(stop.code)" }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let stopReuseIdentifier = "stop"

        var parent: ClusteredStopsMap
        let locationManager = CLLocationManager()
        private var annotationsByStopID: [String: StopAnnotation] = [:]
        private var hasCenteredOnUser = false

        init(parent: ClusteredStopsMap) {
            self.parent = parent
        }

        /// Adds and removes pins so the map shows exactly `stops`, keeping unchanged ones
        /// (and so their clusters) in place.
        func show(_ stops: [GTFSStop], on mapView: MKMapView) {
            let wanted = Dictionary(stops.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let removed = annotationsByStopID.filter { wanted[$0.key] == nil }
            let added = wanted.compactMap { id, stop in annotationsByStopID[id] == nil ? StopAnnotation(stop: stop) : nil }

            if !removed.isEmpty {
                mapView.removeAnnotations(Array(removed.values))
                for id in removed.keys { annotationsByStopID[id] = nil }
            }
            if !added.isEmpty {
                for annotation in added { annotationsByStopID[annotation.stop.id] = annotation }
                mapView.addAnnotations(added)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.onVisibleAreaChange(mapView.region)
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            // Centre on the user once, if they're in the Dublin area.
            guard !hasCenteredOnUser, let location = userLocation.location else { return }
            hasCenteredOnUser = true
            let dublin = CLLocation(latitude: ClusteredStopsMap.defaultRegion.center.latitude,
                                    longitude: ClusteredStopsMap.defaultRegion.center.longitude)
            guard location.distance(from: dublin) < 40_000 else { return }
            mapView.setRegion(MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1000, longitudinalMeters: 1000),
                              animated: true)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            switch annotation {
            case is StopAnnotation:
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.stopReuseIdentifier, for: annotation)
                if let marker = view as? MKMarkerAnnotationView {
                    marker.clusteringIdentifier = "stops"
                    marker.markerTintColor = UIColor(TFIColors.green)
                    marker.glyphImage = UIImage(systemName: "bus.fill")
                    marker.titleVisibility = .adaptive
                    marker.subtitleVisibility = .hidden
                    marker.displayPriority = .defaultHigh
                }
                return view
            case is MKClusterAnnotation:
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: annotation)
                if let marker = view as? MKMarkerAnnotationView {
                    marker.markerTintColor = UIColor(TFIColors.darkGreen)
                    marker.titleVisibility = .hidden
                    marker.subtitleVisibility = .hidden
                }
                return view
            default:
                return nil // the user's location
            }
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            switch annotation {
            case let stop as StopAnnotation:
                parent.onSelectStop(stop.stop)
            case let cluster as MKClusterAnnotation:
                // Zoom in until the cluster splits.
                mapView.deselectAnnotation(cluster, animated: false)
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
            default:
                break
            }
        }
    }
}
