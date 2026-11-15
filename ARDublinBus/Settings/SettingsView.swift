import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if APIKeyStore.bundledKey != nil, !model.keyStore.hasSavedKey {
                        Label("Using the key from the build configuration.", systemImage: "checkmark.seal")
                            .font(.footnote)
                    }
                } header: {
                    Text("NTA real-time API")
                } footer: {
                    Text("Live arrivals come from the National Transport Authority's GTFS-Realtime API. Register for a free key at developer.nationaltransport.ie and subscribe to the GTFS-R product. Without a key, scheduled times are shown.")
                }

                Section {
                    LabeledContent("Status", value: timetableStatus)
                    Button("Download latest timetable") {
                        model.refreshTimetable()
                    }
                    .disabled(isBusy)
                } header: {
                    Text("Timetable")
                } footer: {
                    Text("The Dublin Bus GTFS schedule from transportforireland.ie (about 40 MB). It refreshes automatically every few days.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveAPIKey(apiKey)
                        dismiss()
                    }
                }
            }
            .onAppear {
                apiKey = model.keyStore.hasSavedKey ? (model.keyStore.apiKey ?? "") : ""
            }
        }
    }

    private var isBusy: Bool {
        switch model.timetablePhase {
        case .downloading, .extracting, .indexing: true
        default: false
        }
    }

    private var timetableStatus: String {
        switch model.timetablePhase {
        case .idle: "Not loaded"
        case .downloading(let progress): "Downloading \(Int(progress * 100))%"
        case .extracting: "Extracting…"
        case .indexing: "Loading…"
        case .ready(let date): "Downloaded \(date.formatted(.relative(presentation: .named)))"
        case .failed(let message): "Failed: \(message)"
        }
    }
}
