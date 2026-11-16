import SwiftUI

/// The first screen: gets the timetable onto the device and offers to set the API key.
/// It finishes by itself once both are in place, so on later launches it's only a splash screen
/// while the timetable opens.
struct IntroView: View {
    @Environment(AppModel.self) private var model
    let finish: () -> Void

    /// The user chose to carry on without a key, so don't ask at every launch.
    @AppStorage("skippedAPIKeySetup") private var skippedAPIKey = false
    @State private var apiKey = ""
    @FocusState private var isKeyFocused: Bool

    private var needsAPIKey: Bool { !model.hasAPIKey && !skippedAPIKey }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                timetableCard
                if needsAPIKey { apiKeyCard }
            }
            .padding(.horizontal, 20)
            .padding(.top, 48)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.appBackground)
        .safeAreaInset(edge: .bottom) {
            if needsAPIKey { continueButton }
        }
        .onChange(of: model.isTimetableLoaded, initial: true) { finishIfReady() }
    }

    /// Nothing left to ask or download: go straight to the app.
    private func finishIfReady() {
        if model.isTimetableLoaded, !needsAPIKey { finish() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "bus.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(TFIColors.yellow)
                .frame(width: 88, height: 88)
                .background(TFIColors.green, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            Text("Bus AR")
                .font(.largeTitle.bold())
            Text("Live Dublin Bus departures: on a map, near you, and floating next to the stop sign in your camera.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Timetable

    private var timetableCard: some View {
        card {
            if model.isTimetableLoaded {
                step(icon: "checkmark.circle.fill", tint: .appTint, title: "Timetable ready")
            } else if let error = model.timetableLoadError {
                step(icon: "exclamationmark.triangle.fill", tint: .orange, title: "Couldn't get the timetable", detail: error)
                Button("Try again", action: model.retryTimetable)
                    .buttonStyle(.borderedProminent)
                    .tint(TFIColors.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                switch model.timetablePhase {
                case .downloading(let progress):
                    step(
                        icon: "arrow.down.circle.fill", tint: .appTint,
                        title: "Downloading the timetable",
                        detail: "The Dublin Bus schedule is about 40 MB. This only happens once; later updates happen in the background."
                    )
                    ProgressView(value: progress)
                        .tint(Color.appTint)
                case .extracting:
                    working("Preparing the timetable…", detail: "Unpacking the schedule.")
                case .indexing:
                    working("Preparing the timetable…", detail: "This can take a minute the first time.")
                case .idle, .ready, .failed:
                    working("Opening the timetable…", detail: nil)
                }
            }
        }
    }

    private func working(_ title: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .frame(width: 28, height: 28)
            stepText(title: title, detail: detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - API key

    private var apiKeyCard: some View {
        card {
            step(
                icon: "key.fill", tint: .appTint,
                title: "Live arrivals (optional)",
                detail: "Live times come from the National Transport Authority's GTFS-Realtime API. Register for a free key at developer.nationaltransport.ie and subscribe to the GTFS-R product. Without a key, scheduled times are shown. You can add one later in Settings."
            )
            SecureField("NTA API key", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isKeyFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.appField, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var continueButton: some View {
        Button {
            isKeyFocused = false
            if trimmedKey.isEmpty {
                skippedAPIKey = true
            } else {
                model.saveAPIKey(trimmedKey)
            }
            finish()
        } label: {
            Text(trimmedKey.isEmpty ? "Continue without live times" : "Continue")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(TFIColors.green)
        // The app has nothing to show until the timetable is there.
        .disabled(!model.isTimetableLoaded)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: - Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func step(icon: String, tint: Color, title: String, detail: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
            stepText(title: title, detail: detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepText(title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
