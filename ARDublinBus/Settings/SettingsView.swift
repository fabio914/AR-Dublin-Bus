import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var apiKey = ""
    /// The key as last saved, so "Save" is only offered after an edit.
    @State private var savedKey = ""
    @FocusState private var isKeyFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isKeyFocused)
                    if APIKeyStore.bundledKey != nil, !model.keyStore.hasSavedKey {
                        Label("Using the key from the build configuration.", systemImage: "checkmark.seal")
                            .font(.footnote)
                    }
                } header: {
                    Text("NTA real-time API")
                } footer: {
                    Text("Live arrivals come from the National Transport Authority's GTFS-Realtime API. Register for a free key at developer.nationaltransport.ie and subscribe to the GTFS-R product. Without a key, scheduled times are shown.")
                }
                .listRowBackground(Color.appCard)

                Section {
                    Toggle("Show nearby stops", isOn: Bindable(model).showsARStops)
                } header: {
                    Text("Camera view")
                } footer: {
                    Text("Labels float over the stops around you, placed with GPS and the compass, or with Apple's location anchors where available. Recognising a stop sign sharpens their positions. Tap a label to see its board.")
                }
                .listRowBackground(Color.appCard)

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
                .listRowBackground(Color.appCard)
            }
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
            // Room between the last footer and the tab bar.
            .contentMargins(.bottom, 32, for: .scrollContent)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveAPIKey(apiKey)
                        isKeyFocused = false
                        loadSavedKey()
                    }
                    .disabled(apiKey == savedKey)
                }
            }
            .onAppear(perform: loadSavedKey)
        }
    }

    private func loadSavedKey() {
        savedKey = model.keyStore.hasSavedKey ? (model.keyStore.apiKey ?? "") : ""
        apiKey = savedKey
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
