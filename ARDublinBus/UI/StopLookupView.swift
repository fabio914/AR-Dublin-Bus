import SwiftUI

/// The Search tab: look up a stop by number or name without the camera — handy when a sign
/// can't be read, and for trying the app in the Simulator. Matching stops are listed as you type.
struct StopLookupView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @State private var results: [StopSearchResult] = []
    /// The query `results` are for (`nil` before the first search finishes).
    @State private var searchedQuery: String?
    @State private var searchError: String?
    @State private var selectedCode: String?
    @FocusState private var isInputFocused: Bool

    private var query: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField("Stop number or name", text: $input)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .focused($isInputFocused)
                                .onSubmit(show)
                            if !input.isEmpty {
                                Button {
                                    // Start a new search straight away.
                                    input = ""
                                    isInputFocused = true
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.appCard, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        // Only while typing; the keyboard's own search key does the same.
                        if isInputFocused {
                            Button("Search", action: show)
                                .buttonStyle(.borderedProminent)
                                .tint(TFIColors.green)
                                .disabled(query.isEmpty)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .animation(.default, value: isInputFocused)
                    content
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.appBackground)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .tripDestination()
        }
        // Ready to type as soon as the tab opens.
        .onAppear { isInputFocused = true }
        .onChange(of: input) { selectedCode = nil }
        .task(id: query) {
            guard !query.isEmpty else {
                results = []
                searchedQuery = nil
                return
            }
            // Wait for a pause in typing.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            _ = await search(query)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let selectedCode {
            if results.count > 1 {
                Button {
                    self.selectedCode = nil
                } label: {
                    Label("All results", systemImage: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .tint(Color.appTint)
            }
            StopBoardView(stopCode: selectedCode)
        } else if query.isEmpty {
            Text("Type a stop number, like 271, or part of a stop's name, like O'Connell.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let searchError {
            Label(searchError, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if searchedQuery == nil {
            ProgressView()
                .padding(.top, 24)
        } else if results.isEmpty {
            Text("No stops match “\(searchedQuery ?? query)”.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            StopResultsCard(results: results) { result in
                selectedCode = result.stop.code
                isInputFocused = false
            }
        }
    }

    /// Searches now, without waiting for a pause in typing. Returns `nil` if it failed.
    private func search(_ query: String) async -> [StopSearchResult]? {
        do {
            let found = try await model.service.searchStops(query)
            guard query == self.query else { return nil } // the text changed meanwhile
            results = found
            searchedQuery = query
            searchError = nil
            return found
        } catch {
            searchError = error.localizedDescription
            return nil
        }
    }

    /// Completes the search and hides the keyboard. A stop number, or a search with a single
    /// result, opens that stop's board straight away.
    private func show() {
        let query = self.query
        guard !query.isEmpty else { return }
        isInputFocused = false
        Task {
            guard let found = await search(query) else { return }
            if let number = StopNumberParser.normalize(query), let exact = found.first(where: { $0.stop.code == number }) {
                selectedCode = exact.stop.code
            } else if found.count == 1 {
                selectedCode = found[0].stop.code
            }
        }
    }
}

/// Matching stops, each with the routes that call there.
private struct StopResultsCard: View {
    let results: [StopSearchResult]
    let select: (StopSearchResult) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                if index > 0 { PanelSeparator() }
                Button { select(result) } label: {
                    StopResultRow(result: result)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        .environment(\.colorScheme, .light)
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

private struct StopResultRow: View {
    let result: StopSearchResult
    static let maximumRoutes = 8

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bus.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(TFIColors.green, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(result.stop.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TFIColors.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("Stop \(result.stop.code)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TFIColors.secondaryInk)
                        .fixedSize()
                    // As many route badges as fit, then "+N" for the rest.
                    ViewThatFits(in: .horizontal) {
                        ForEach(Array(stride(from: min(result.routes.count, Self.maximumRoutes), through: 0, by: -1)), id: \.self) { count in
                            routeBadges(count)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TFIColors.secondaryInk.opacity(0.7))
        }
        .padding(.horizontal, PanelMetrics.horizontalPadding)
        .padding(.vertical, 10)
    }

    private func routeBadges(_ count: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(result.routes.prefix(count), id: \.self) { route in
                Text(route)
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(TFIColors.ink)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(TFIColors.yellow, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            if result.routes.count > count {
                Text("+\(result.routes.count - count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TFIColors.secondaryInk)
            }
        }
        .fixedSize()
    }
}
