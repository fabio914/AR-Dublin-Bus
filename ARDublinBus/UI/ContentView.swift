import ARKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false
    @State private var showingLookup = false
    @State private var showingNearby = false

    var body: some View {
        ZStack {
            if ARWorldTrackingConfiguration.isSupported {
                BusStopARView(model: model)
                    .ignoresSafeArea()
            } else {
                unsupportedView
            }

            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    StatusBadge(model: model)
                    Spacer()
                    toolbarButton("location.fill", label: "Stops near me") { showingNearby = true }
                    toolbarButton("magnifyingglass", label: "Look up a stop") { showingLookup = true }
                    toolbarButton("gearshape.fill", label: "Settings") { showingSettings = true }
                }
                TimetableBanner(phase: model.timetablePhase, retry: model.retryTimetable)
                Spacer()
                if !model.hasAPIKey {
                    APIKeyHint { showingSettings = true }
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
        .task {
            if !ARWorldTrackingConfiguration.isSupported { model.trackingStatus = .unsupported }
            await model.start()
        }
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
