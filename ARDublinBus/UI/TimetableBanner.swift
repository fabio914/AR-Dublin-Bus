import SwiftUI

/// Progress of the timetable download, or why it failed. Empty once the timetable is ready.
struct TimetableBanner: View {
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
