import SwiftUI

/// Look up a stop by number without the camera — handy when a sign can't be read,
/// and for trying the app in the Simulator.
struct StopLookupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var stopCode: String?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    HStack {
                        TextField("Stop number, e.g. 271", text: $input)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .focused($isInputFocused)
                            .onSubmit(lookUp)
                        Button("Show", action: lookUp)
                            .buttonStyle(.borderedProminent)
                            .tint(TFIColors.green)
                            .disabled(StopNumberParser.normalize(input.trimmingCharacters(in: .whitespaces)) == nil)
                    }

                    if let stopCode {
                        StopBoardView(stopCode: stopCode)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Look up a stop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .tripDestination()
        }
        // Ready to type as soon as the sheet opens.
        .onAppear { isInputFocused = true }
    }

    private func lookUp() {
        guard let code = StopNumberParser.normalize(input.trimmingCharacters(in: .whitespaces)) else { return }
        stopCode = code
        // Hide the keyboard so the board is fully visible.
        isInputFocused = false
    }
}
