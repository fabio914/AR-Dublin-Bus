import CoreLocation
import Foundation

/// A route that leaves a stop, with where it goes from there. Comes from the timetable, so
/// every route serving the stop is listed, whether or not a bus is due.
struct StopLine: Identifiable, Sendable {
    let route: GTFSRoute
    /// Destinations from this stop, the most frequent first.
    let headsigns: [String]
    /// The route's path from this stop onwards, one per distinct way the route runs from here.
    let paths: [[CLLocationCoordinate2D]]

    var id: String { route.id }
}

/// Every route leaving a stop, for the stop screen's map and list.
struct StopLines: Sendable {
    let stop: GTFSStop
    let lines: [StopLine]
}

/// Cuts a route's path so it starts at a given stop.
enum StopLinePath {
    /// A point of the shape counts as passing a stop within this many metres.
    static let matchDistance: CLLocationDistance = 60
    /// Once a stop is passed, the search stops when the shape is this much farther away again.
    static let leaveDistance: CLLocationDistance = 400

    /// The part of `shape` from the stop at `target` onwards.
    ///
    /// The trip's stops (`stops`, in order) are matched to the shape one after the other, each
    /// from where the previous one matched, so a route passing the same place twice (a loop,
    /// or the other direction on the same road) is cut where the bus actually reaches the stop.
    /// Stops without a position are `nil`. Falls back to the stops themselves when the shape
    /// is missing or the result would be a single point.
    ///
    /// - Returns: the path, and the index in `shape` it starts at (`nil` for the fallback).
    static func remainder(of shape: [CLLocationCoordinate2D], stops: [CLLocationCoordinate2D?], target: Int)
        -> (path: [CLLocationCoordinate2D], shapeStart: Int?) {
        let fallback = (path: stops[target...].compactMap { $0 }, shapeStart: Int?.none)
        guard shape.count > 1, stops.indices.contains(target), stops[target] != nil else { return fallback }

        var start = 0
        for stop in stops[...target] {
            guard let stop else { continue }
            start = closestPoint(to: stop, in: shape, from: start)
        }
        return shape.count - start > 1 ? (Array(shape[start...]), start) : fallback
    }

    /// The index of the first close approach to `point` at or after `start`, or the nearest
    /// point if the shape never comes within `matchDistance`.
    private static func closestPoint(to point: CLLocationCoordinate2D, in shape: [CLLocationCoordinate2D], from start: Int) -> Int {
        var best = start
        var bestDistance = CLLocationDistance.infinity
        for index in start..<shape.count {
            let distance = approximateDistance(point, shape[index])
            if distance < bestDistance {
                best = index
                bestDistance = distance
            } else if bestDistance <= matchDistance, distance > bestDistance + leaveDistance {
                break
            }
        }
        return best
    }

    /// Metres, accurate enough over a city.
    static func approximateDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let metresPerDegree = 111_195.0
        let x = (b.longitude - a.longitude) * cos((a.latitude + b.latitude) / 2 * .pi / 180) * metresPerDegree
        let y = (b.latitude - a.latitude) * metresPerDegree
        return (x * x + y * y).squareRoot()
    }
}
