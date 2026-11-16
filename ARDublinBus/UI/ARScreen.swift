import ARKit
import SwiftUI

/// The camera view: recognises stop signs and floats boards and nearby-stop labels over them.
/// Pushed from the map, with the tab bar hidden so the camera fills the screen.
struct ARScreen: View {
    @Environment(AppModel.self) private var model
    /// Switches to the Settings tab, for adding an API key.
    let openSettings: () -> Void
    @State private var isVisible = true

    var body: some View {
        ZStack {
            if ARWorldTrackingConfiguration.isSupported {
                // Not running while another tab is in front.
                BusStopARView(model: model, isPaused: !isVisible)
                    .ignoresSafeArea()
            } else {
                unsupportedView
            }

            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    StatusBadge(model: model)
                    ARStopsBadge(status: model.arStopsStatus)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                TimetableBanner(phase: model.timetablePhase, retry: model.retryTimetable)
                Spacer()
                if !model.hasAPIKey {
                    APIKeyHint(action: openSettings)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .navigationTitle("AR")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: Bindable(model).selectedARStop) { stop in
            StopBoardSheet(stop: stop) { model.selectedARStop = nil }
        }
        .onAppear {
            isVisible = true
            if !ARWorldTrackingConfiguration.isSupported { model.trackingStatus = .unsupported }
        }
        .onDisappear { isVisible = false }
    }

    private var unsupportedView: some View {
        ContentUnavailableView(
            "AR isn't available",
            systemImage: "arkit",
            description: Text("This device can't run ARKit world tracking. You can still find stops in the Map, Nearby and Search tabs.")
        )
    }
}

private struct StatusBadge: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(TFIColors.yellow)
            Text(text)
                .lineLimit(2)
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(TFIColors.green.opacity(0.92), in: Capsule())
        .animation(.default, value: text)
    }

    private var icon: String {
        switch model.trackingStatus {
        case .starting, .searching: "viewfinder"
        case .readingNumber: "text.viewfinder"
        case .tracking: "bus.fill"
        case .unsupported, .failed: "exclamationmark.triangle.fill"
        }
    }

    private var text: String {
        switch model.trackingStatus {
        case .starting: "Starting camera…"
        case .searching: "Point the camera at a bus stop sign"
        case .readingNumber(let needsCloserLook): needsCloserLook ? "Move closer to read the stop number" : "Reading the stop number…"
        case .tracking(let code): "Stop \(code)"
        case .unsupported: "AR isn't supported on this device"
        case .failed(let message): message
        }
    }
}

/// How nearby stops are placed in the AR view.
private struct ARStopsBadge: View {
    let status: ARStopsStatus

    var body: some View {
        if let text {
            Label(text, systemImage: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.45), in: Capsule())
                .animation(.default, value: text)
        }
    }

    private var icon: String {
        status.mode == .geo ? "location.viewfinder" : "mappin.and.ellipse"
    }

    private var stops: String {
        status.stopCount == 1 ? "1 stop nearby" : "\(status.stopCount) stops nearby"
    }

    private var text: String? {
        switch status.mode {
        case .off:
            nil
        case .unavailable:
            "Nearby stops need location access and the compass"
        case .waitingForLocation:
            "Finding stops around you…"
        case .compass, .geoLocalizing:
            [
                stops,
                status.isCorrectedBySign ? "aligned to a sign"
                    : status.expectedError.map { "GPS ±\(Int($0.rounded())) m" },
                status.mode == .geoLocalizing ? "point at buildings to sharpen" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
        case .geo:
            "\(stops) · location anchors"
        }
    }
}

private struct APIKeyHint: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Showing timetable times. Add an NTA API key for live arrivals.", systemImage: "key.fill")
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .foregroundStyle(.primary)
    }
}
