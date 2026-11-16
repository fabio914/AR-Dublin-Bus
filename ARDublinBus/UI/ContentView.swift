import ARKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false
    @State private var showingLookup = false
    @State private var showingNearby = false
    @State private var showingMap = false

    var body: some View {
        ZStack {
            if ARWorldTrackingConfiguration.isSupported {
                BusStopARView(model: model, isPaused: coversCamera)
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
                HStack(alignment: .bottom, spacing: 12) {
                    if !model.hasAPIKey {
                        APIKeyHint { showingSettings = true }
                    } else {
                        Spacer()
                    }
                    // Within thumb reach, and out of the way of the camera view.
                    VStack(spacing: 12) {
                        toolbarButton("location.fill", label: "Stops near me") { showingNearby = true }
                        toolbarButton("map.fill", label: "Map of bus stops") { showingMap = true }
                        toolbarButton("magnifyingglass", label: "Look up a stop") { showingLookup = true }
                        toolbarButton("gearshape.fill", label: "Settings") { showingSettings = true }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingLookup) {
            StopLookupView()
        }
        .sheet(isPresented: $showingNearby) {
            NearbyStopsView()
        }
        .sheet(isPresented: $showingMap) {
            StopsMapView()
        }
        .sheet(item: Bindable(model).selectedARStop) { stop in
            StopBoardSheet(stop: stop) { model.selectedARStop = nil }
        }
        .task {
            if !ARWorldTrackingConfiguration.isSupported { model.trackingStatus = .unsupported }
            await model.start()
        }
    }

    /// A full-height sheet hides the camera view. (A stop's board opened from an AR label is
    /// half-height, with the camera still visible behind it.)
    private var coversCamera: Bool {
        showingSettings || showingLookup || showingNearby || showingMap
    }

    private func toolbarButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }

    private var unsupportedView: some View {
        ContentUnavailableView(
            "AR isn't available",
            systemImage: "arkit",
            description: Text("This device can't run ARKit world tracking. You can still look up a stop with the search button.")
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

private struct TimetableBanner: View {
    let phase: TimetablePhase
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .downloading(let progress):
            banner {
                ProgressView(value: progress) {
                    Text("Downloading the Dublin Bus timetable…")
                }
            }
        case .extracting, .indexing:
            banner {
                HStack {
                    ProgressView()
                    Text("Preparing the timetable…")
                }
            }
        case .failed(let message):
            banner {
                HStack {
                    Text("Timetable unavailable: \(message)")
                        .lineLimit(3)
                    Spacer()
                    Button("Retry", action: retry)
                        .buttonStyle(.borderedProminent)
                        .tint(TFIColors.green)
                }
            }
        case .idle, .ready:
            EmptyView()
        }
    }

    private func banner<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.footnote)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
