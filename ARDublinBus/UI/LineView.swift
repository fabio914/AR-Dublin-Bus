import SwiftUI

/// A route as seen from one stop: its path on a map with the buses running it, every stop,
/// and the timetable at the stop. Opened from the Lines card of a stop.
struct LineView: View {
    @Environment(AppModel.self) private var model
    let reference: LineReference
    @State private var details: LineDetails?
    @State private var error: String?
    @State private var directionID: String?
    @State private var section = Section.stops
    /// `nil` until loaded, or when positions are unavailable.
    @State private var vehicles: [VehiclePosition]?

    enum Section: String, CaseIterable, Identifiable {
        case stops = "Stops"
        case timetable = "Timetable"
        var id: Self { self }
    }

    static let refreshInterval: Duration = .seconds(30)

    var body: some View {
        Group {
            if let details, let direction = direction(in: details) {
                VStack(spacing: 0) {
                    map(details: details, direction: direction)
                        .frame(height: 260)
                    content(details: details, direction: direction)
                }
            } else if details != nil {
                ContentUnavailableView("No buses leave from here", systemImage: "moon.zzz.fill",
                                       description: Text("This route doesn't pick up passengers at stop \(reference.stopCode)."))
            } else if let error {
                ContentUnavailableView("Couldn't load this route", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView("Loading the route…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.appBackground)
        .navigationTitle(details.map { "Route \($0.route.shortName)" } ?? "Route")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reference) {
            do {
                details = try await model.service.line(reference)
            } catch {
                self.error = error.localizedDescription
            }
        }
        .task(id: details.flatMap(direction(in:))?.id) {
            guard let tripIDs = details.flatMap(direction(in:))?.tripIDs else { return }
            vehicles = nil
            while !Task.isCancelled {
                let positions = await model.service.vehicles(forTripIDs: tripIDs)
                if !Task.isCancelled { vehicles = positions }
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    private func direction(in details: LineDetails) -> LineDirection? {
        details.directions.first { $0.id == directionID } ?? details.directions.first
    }

    private func map(details: LineDetails, direction: LineDirection) -> some View {
        RouteMap(
            path: direction.shape,
            stops: direction.stops.map { RouteMap.Stop(id: $0.sequence, stop: $0.stop) },
            highlighted: direction.stops[direction.stopIndex].stop,
            vehicles: vehicles ?? [],
            routeKey: direction.id
        )
        .overlay(alignment: .bottomLeading) {
            if let vehicles {
                let count = vehicles.count
                MapCaption(
                    systemImage: "dot.radiowaves.left.and.right",
                    text: Text(count == 0 ? "No buses on the road" : "\(count) bus\(count == 1 ? "" : "es") on the road")
                )
            }
        }
    }

    private func content(details: LineDetails, direction: LineDirection) -> some View {
        VStack(spacing: 0) {
            // Kept in view while the list scrolls to the user's stop.
            VStack(spacing: 10) {
                if details.directions.count > 1 {
                    directionPicker(details.directions, selected: direction)
                }
                Picker("Show", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    switch section {
                    case .timetable:
                        LineTimetableCard(details: details, direction: direction)
                            .padding([.horizontal, .bottom], 16)
                    case .stops:
                        LineStopsCard(route: details.route, direction: direction)
                            .padding([.horizontal, .bottom], 16)
                    }
                }
                .onAppear { scrollToStop(proxy, direction: direction) }
                .onChange(of: section) { scrollToStop(proxy, direction: direction) }
                .onChange(of: direction.id) { scrollToStop(proxy, direction: direction) }
            }
        }
    }

    private func scrollToStop(_ proxy: ScrollViewProxy, direction: LineDirection) {
        guard section == .stops else { return }
        // After the list is laid out.
        Task { @MainActor in
            proxy.scrollTo(direction.stops[direction.stopIndex].id, anchor: .center)
        }
    }

    private func directionPicker(_ directions: [LineDirection], selected: LineDirection) -> some View {
        HStack {
            Text("Towards")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.cardSecondaryInk)
            Spacer(minLength: 8)
            Picker("Towards", selection: Binding(get: { selected.id }, set: { directionID = $0 })) {
                ForEach(directions) { Text($0.headsign).tag($0.id) }
            }
            .pickerStyle(.menu)
            .tint(Color.appTint)
        }
        .padding(.leading, PanelMetrics.horizontalPadding)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Stops

/// Every stop of a typical trip as a timeline, with the time it takes to get there.
private struct LineStopsCard: View {
    let route: GTFSRoute
    let direction: LineDirection

    var body: some View {
        PanelCard(title: "To \(direction.headsign)", subtitle: subtitle, icon: "point.topleft.down.to.point.bottomright.curvepath.fill") {
            VStack(spacing: 0) {
                ForEach(Array(direction.stops.enumerated()), id: \.element.id) { index, stop in
                    LineStopRow(
                        stop: stop,
                        position: index < direction.stopIndex ? .before : index == direction.stopIndex ? .here : .after,
                        isFirst: index == 0,
                        isLast: index == direction.stops.count - 1
                    )
                    .id(stop.id)
                }
            }
            .padding(.vertical, 6)
            PanelFooter {
                Image(systemName: "clock")
                Text("Typical journey times from your stop")
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }

    private var subtitle: String {
        let count = direction.stops.count
        return "Route \(route.shortName) · \(count) stop\(count == 1 ? "" : "s")"
    }
}

private struct LineStopRow: View {
    enum Position { case before, here, after }

    let stop: LineDirection.Stop
    let position: Position
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(spacing: 12) {
            RouteTimelineMarker(isHighlighted: position == .here, isDimmed: position == .before, isFirst: isFirst, isLast: isLast)
            VStack(alignment: .leading, spacing: 1) {
                Text(stop.stop.name)
                    .font(.system(size: 16, weight: position == .here ? .bold : .medium))
                    .foregroundStyle(position == .before ? Color.cardSecondaryInk : Color.cardInk)
                    .lineLimit(2)
                Text("Stop \(stop.stop.code)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.cardSecondaryInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            trailing
        }
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .background(position == .here ? TFIColors.yellow.opacity(0.22) : .clear)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailing: some View {
        switch position {
        case .here:
            Text("Your stop")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.cardInk)
        case .after:
            Text("\(max(0, Int((Double(stop.offset) / 60).rounded()))) min")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.cardSecondaryInk)
                .monospacedDigit()
        case .before:
            EmptyView()
        }
    }
}

// MARK: - Timetable

/// The times buses leave the stop, by hour, for a day picked from the coming week.
private struct LineTimetableCard: View {
    let details: LineDetails
    let direction: LineDirection
    @State private var dayOffset = 0

    static let days = 7

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let today = GTFSDate(date: context.date)
            let date = today.adding(days: dayOffset)
            let departures = direction.timetable(on: date, services: details.services)
            let next = dayOffset == 0 ? departures.first { $0.time >= context.date } : nil

            PanelCard(title: "Timetable", subtitle: "From stop \(details.stop.code) · \(dayName(date, today: today))", icon: "calendar") {
                dayPicker(today: today)
                    .padding(.vertical, 10)
                PanelSeparator()
                if departures.isEmpty {
                    PanelMessage(icon: "moon.zzz.fill", title: "No buses to \(direction.headsign) on this day")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(hours(departures).enumerated()), id: \.offset) { index, hour in
                            if index > 0 { PanelSeparator() }
                            HourRow(hour: hour.hour, departures: hour.departures, now: dayOffset == 0 ? context.date : nil, next: next)
                        }
                    }
                    .padding(.vertical, 4)
                }
                PanelFooter {
                    Image(systemName: "hand.tap")
                    Text("Tap a time to follow that bus")
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
        }
    }

    private func dayPicker(today: GTFSDate) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<Self.days, id: \.self) { offset in
                    let isSelected = offset == dayOffset
                    Button {
                        withAnimation { dayOffset = offset }
                    } label: {
                        Text(dayName(today.adding(days: offset), today: today))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isSelected ? .white : Color.cardInk)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(isSelected ? TFIColors.green : Color.appField, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, PanelMetrics.horizontalPadding)
        }
    }

    private func dayName(_ date: GTFSDate, today: GTFSDate) -> String {
        if date == today { return "Today" }
        if date == today.adding(days: 1) { return "Tomorrow" }
        let noon = date.serviceDayReference().addingTimeInterval(12 * 3600)
        return noon.formatted(Date.FormatStyle(timeZone: Dublin.timeZone).weekday(.abbreviated).day())
    }

    /// Consecutive departures in the same clock hour (after midnight comes last, as on paper).
    private func hours(_ departures: [LineDirection.ScheduledDeparture]) -> [(hour: Int, departures: [LineDirection.ScheduledDeparture])] {
        var result: [(hour: Int, departures: [LineDirection.ScheduledDeparture])] = []
        for departure in departures {
            let hour = Dublin.calendar.component(.hour, from: departure.time)
            if result.last?.hour == hour {
                result[result.count - 1].departures.append(departure)
            } else {
                result.append((hour, [departure]))
            }
        }
        return result
    }
}

private struct HourRow: View {
    let hour: Int
    let departures: [LineDirection.ScheduledDeparture]
    /// Set for today, so the buses that have left are greyed out.
    let now: Date?
    let next: LineDirection.ScheduledDeparture?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(String(format: "%02d", hour))
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(Color.cardInk)
                .monospacedDigit()
                .frame(width: 30, alignment: .leading)
                .padding(.top, 5)
                .accessibilityLabel("\(hour) o'clock")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(departures) { departure in
                    NavigationLink(value: departure.trip) {
                        minute(departure)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ETAText.clock(departure.time))
                }
            }
        }
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, 8)
    }

    private func minute(_ departure: LineDirection.ScheduledDeparture) -> some View {
        let isNext = departure.id == next?.id
        let hasLeft = now.map { departure.time < $0 } ?? false
        let minute = Dublin.calendar.component(.minute, from: departure.time)
        return Text(String(format: "%02d", minute))
            .font(.system(size: 16, weight: isNext ? .bold : .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isNext ? TFIColors.ink : hasLeft ? Color.cardSecondaryInk.opacity(0.6) : Color.cardInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(isNext ? TFIColors.yellow : Color.appField.opacity(hasLeft ? 0.5 : 1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
