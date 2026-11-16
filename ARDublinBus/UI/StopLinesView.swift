import MapKit
import SwiftUI

/// A line's colour on the stop screen: the hue circle is split evenly between the stop's
/// lines, at saturation 0.8 and a high brightness, so each line stands apart on the map.
struct LineColour {
    let fill: Color
    /// White or ink, whichever reads better on `fill`.
    let text: Color

    static let saturation = 0.8
    static let brightness = 0.95

    init(index: Int, count: Int) {
        let hue = Double(index) / Double(max(count, 1))
        let (red, green, blue) = Self.rgb(hue: hue, saturation: Self.saturation, brightness: Self.brightness)
        fill = Color(red: red, green: green, blue: blue)

        // WCAG relative luminance, then the text colour with the higher contrast.
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let inkLuminance = 0.012
        let contrastWithWhite = 1.05 / (luminance + 0.05)
        let contrastWithInk = (luminance + 0.05) / (inkLuminance + 0.05)
        text = contrastWithWhite > contrastWithInk ? .white : TFIColors.ink
    }

    /// One colour per line, keyed by `StopLine.id`, in the order given.
    static func colours(for lines: [StopLine]) -> [String: LineColour] {
        Dictionary(uniqueKeysWithValues: lines.enumerated().map { ($1.id, LineColour(index: $0, count: lines.count)) })
    }

    static func rgb(hue: Double, saturation: Double, brightness: Double) -> (Double, Double, Double) {
        let sector = (hue - hue.rounded(.down)) * 6
        let chroma = brightness * saturation
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - chroma
        let (r, g, b): (Double, Double, Double) = switch Int(sector) {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        return (r + m, g + m, b + m)
    }
}

/// Where every line goes from the stop, each in its own colour. With a line selected, the
/// others fade and the map zooms to it.
struct StopLinesMap: View {
    let overview: StopLines
    let colours: [String: LineColour]
    let selectedLineID: String?
    @State private var position: MapCameraPosition

    init(overview: StopLines, colours: [String: LineColour], selectedLineID: String?) {
        self.overview = overview
        self.colours = colours
        self.selectedLineID = selectedLineID
        _position = State(initialValue: Self.cameraPosition(for: overview.lines, stop: overview.stop))
    }

    var body: some View {
        Map(position: $position) {
            // The selected line is drawn last, so it's on top.
            ForEach(drawingOrder) { line in
                let isSelected = line.id == selectedLineID
                let isDimmed = selectedLineID != nil && !isSelected
                let colour = colours[line.id]?.fill ?? Color.appTint
                ForEach(Array(line.paths.enumerated()), id: \.offset) { _, path in
                    MapPolyline(coordinates: path)
                        .stroke(colour.opacity(isDimmed ? 0.18 : 1),
                                style: StrokeStyle(lineWidth: isSelected ? 6 : 4, lineCap: .round, lineJoin: .round))
                }
            }

            if let coordinate = overview.stop.coordinate {
                Annotation(overview.stop.name, coordinate: coordinate) {
                    Image(systemName: "bus.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(TFIColors.ink)
                        .frame(width: 28, height: 28)
                        .background(TFIColors.yellow, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(radius: 2)
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
        .onChange(of: selectedLineID) { _, id in
            let lines = overview.lines.filter { $0.id == id }
            withAnimation {
                position = Self.cameraPosition(for: lines.isEmpty ? overview.lines : lines, stop: overview.stop)
            }
        }
    }

    private var drawingOrder: [StopLine] {
        overview.lines.filter { $0.id != selectedLineID } + overview.lines.filter { $0.id == selectedLineID }
    }

    /// Every path of `lines` and the stop, with some padding.
    static func cameraPosition(for lines: [StopLine], stop: GTFSStop) -> MapCameraPosition {
        var points = lines.flatMap { $0.paths.joined() }
        if let coordinate = stop.coordinate { points.append(coordinate) }
        guard !points.isEmpty else { return .automatic }
        var rect = MKPolyline(coordinates: points, count: points.count).boundingMapRect
        let padding = max(rect.width, rect.height) * 0.08 + 300
        rect = rect.insetBy(dx: -padding, dy: -padding)
        return .rect(rect)
    }
}

/// Every line leaving the stop, whether or not a bus is due: a map of where each goes, then
/// the lines in the map's colours with their next bus. Tapping a line shows it alone on the map.
struct StopLinesCard: View {
    /// `nil` while loading.
    let overview: StopLines?
    let error: String?
    /// For each line's next bus; `nil` while loading.
    let board: StopBoard?
    let now: Date
    @Binding var selectedLineID: String?

    static let mapHeight: CGFloat = 240

    var body: some View {
        PanelCard(title: "Lines", subtitle: subtitle, icon: "point.topleft.down.to.point.bottomright.curvepath.fill") {
            if let overview {
                let colours = LineColour.colours(for: overview.lines)
                if overview.lines.isEmpty {
                    PanelMessage(icon: "moon.zzz.fill", title: "No routes leave from this stop")
                } else {
                    StopLinesMap(overview: overview, colours: colours, selectedLineID: selectedLineID)
                        .frame(height: Self.mapHeight)
                    lineRows(overview.lines, colours: colours)
                    PanelFooter {
                        Image(systemName: "hand.tap")
                        Text(selectedLineID == nil ? "Tap a line to show it alone on the map" : "Tap it again to show every line")
                    }
                }
            } else if let error {
                PanelMessage(icon: "exclamationmark.triangle.fill", title: "Couldn't load the lines", detail: error)
            } else {
                ProgressView()
                    .frame(height: Self.mapHeight)
                    .frame(maxWidth: .infinity)
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    private var subtitle: String? {
        guard let count = overview?.lines.count else { return nil }
        return "\(count) route\(count == 1 ? "" : "s") from this stop"
    }

    private func lineRows(_ lines: [StopLine], colours: [String: LineColour]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                if index > 0 { PanelSeparator() }
                Button {
                    withAnimation { selectedLineID = selectedLineID == line.id ? nil : line.id }
                } label: {
                    StopLineRow(
                        line: line,
                        colour: colours[line.id],
                        nextBus: nextBusText(for: line),
                        isSelected: selectedLineID == line.id
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func nextBusText(for line: StopLine) -> String? {
        guard let board else { return nil }
        guard let next = board.departures.first(where: { $0.route == line.route.shortName && !$0.isCancelled }) else {
            return "No buses in the next 90 minutes"
        }
        // Live times count down, like the board; timetable times are clock times.
        let minutes = ETAText.minutes(until: next.expected, from: now)
        if next.isRealtime, minutes == 0 { return "Next bus due now" }
        if next.isRealtime, minutes < 60 { return "Next bus in \(minutes) min" }
        return "Next bus at \(ETAText.clock(next.expected))"
    }
}

private struct StopLineRow: View {
    let line: StopLine
    let colour: LineColour?
    let nextBus: String?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(line.route.shortName)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(colour?.text ?? TFIColors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 56, height: 34)
                .background(colour?.fill ?? TFIColors.yellow, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(destinations)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(TFIColors.ink)
                    .lineLimit(2)
                if let nextBus {
                    Text(nextBus)
                        .font(.system(size: 13))
                        .foregroundStyle(TFIColors.secondaryInk)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: isSelected ? "eye.fill" : "eye")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isSelected ? TFIColors.green : TFIColors.secondaryInk.opacity(0.6))
        }
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, 9)
        .background(isSelected ? (colour?.fill ?? TFIColors.yellow).opacity(0.15) : .clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var destinations: String {
        line.headsigns.isEmpty ? line.route.longName : "To " + line.headsigns.joined(separator: " · ")
    }
}
