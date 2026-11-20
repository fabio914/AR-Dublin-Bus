import Foundation
import Observation

enum TrackingStatus: Equatable {
    case starting
    case searching
    case readingNumber(needsCloserLook: Bool)
    case tracking(stopCode: String)
    case unsupported
    case failed(String)
}

/// What the floating AR panel currently shows.
enum PanelContent: Equatable {
    case reading(hint: String?)
    case loading(stopCode: String)
    case board(StopBoard)
    case failure(stopCode: String?, message: String)
}

@MainActor
@Observable
final class AppModel {
    let service: DepartureService
    /// Stops the user starred, listed on the Search tab.
    let favourites = FavouriteStops()
    @ObservationIgnored let keyStore: APIKeyStore
    @ObservationIgnored private let watchResponder: WatchResponder

    var timetablePhase: TimetablePhase = .idle
    var trackingStatus: TrackingStatus = .starting
    private(set) var activeStopCode: String?
    private(set) var panelContent: PanelContent = .reading(hint: nil)
    /// Valid stop codes once the timetable is loaded; used to reject OCR misreads.
    private(set) var knownStopCodes: Set<String>?
    private(set) var hasAPIKey: Bool
    /// The timetable has been downloaded and opened, so the app's screens have data to show.
    private(set) var isTimetableLoaded = false
    /// Why the timetable couldn't be loaded, until the next attempt.
    private(set) var timetableLoadError: String?

    /// Nearby stops shown as labels in the AR view.
    var showsARStops: Bool {
        didSet {
            UserDefaults.standard.set(showsARStops, forKey: Self.showsARStopsKey)
            onShowsARStopsChange?(showsARStops)
        }
    }
    var arStopsStatus = ARStopsStatus()
    /// A stop tapped in the AR view, whose board is shown in a sheet.
    var selectedARStop: GTFSStop?
    @ObservationIgnored var onShowsARStopsChange: ((Bool) -> Void)?
    private static let showsARStopsKey = "showsARStops"

    /// Called whenever `panelContent` changes, so the AR panel can be re-rendered.
    @ObservationIgnored var onPanelContentChange: ((PanelContent) -> Void)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// How often the board is rebuilt (the realtime feed itself is cached for longer).
    static let refreshInterval: Duration = .seconds(15)

    init(keyStore: APIKeyStore = .shared) {
        self.keyStore = keyStore
        hasAPIKey = keyStore.apiKey != nil
        showsARStops = UserDefaults.standard.object(forKey: Self.showsARStopsKey) as? Bool ?? true
        service = DepartureService(
            timetableStore: TimetableStore(),
            realtimeClient: RealtimeClient(apiKey: { keyStore.apiKey })
        )
        // Activated right away: a watch request may be what launched the app.
        watchResponder = WatchResponder(service: service)
        watchResponder.activate()
    }

    func start() async {
        await service.timetableStore.setPhaseHandler { [weak self] phase in
            Task { @MainActor in self?.timetablePhase = phase }
        }
        await loadStopCodes()
    }

    func retryTimetable() {
        Task { await loadStopCodes() }
    }

    func refreshTimetable() {
        Task {
            _ = try? await service.timetableStore.refresh()
            await loadStopCodes()
        }
    }

    private func loadStopCodes() async {
        timetableLoadError = nil
        do {
            knownStopCodes = try await service.knownStopCodes()
            isTimetableLoaded = true
        } catch {
            // A failed refresh leaves the timetable that was already loaded in use.
            if !isTimetableLoaded { timetableLoadError = error.localizedDescription }
        }
    }

    func saveAPIKey(_ key: String) {
        let previous = keyStore.apiKey
        keyStore.save(key)
        hasAPIKey = keyStore.apiKey != nil
        // Saving the same key again mustn't refetch the feed (the NTA asks for one fetch a minute).
        guard keyStore.apiKey != previous else { return }
        Task {
            await service.realtimeClient.reset()
            if let code = activeStopCode { await refreshBoard(code) }
        }
    }

    // MARK: - Sign lifecycle (driven by the AR coordinator)

    func signDetected() {
        activeStopCode = nil
        refreshTask?.cancel()
        trackingStatus = .readingNumber(needsCloserLook: false)
        setPanel(.reading(hint: nil))
    }

    func readingIsSlow() {
        guard activeStopCode == nil, trackingStatus != .readingNumber(needsCloserLook: true) else { return }
        trackingStatus = .readingNumber(needsCloserLook: true)
        setPanel(.reading(hint: "Move closer so the stop number is in view"))
    }

    func activate(stopCode: String) {
        guard stopCode != activeStopCode else { return }
        activeStopCode = stopCode
        trackingStatus = .tracking(stopCode: stopCode)
        setPanel(.loading(stopCode: stopCode))

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshBoard(stopCode)
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    /// The stop's card folded away: stop refreshing its board, unless another stop took over.
    func deactivate(stopCode: String) {
        guard activeStopCode == stopCode else { return }
        signLost()
    }

    func signLost() {
        activeStopCode = nil
        refreshTask?.cancel()
        refreshTask = nil
        trackingStatus = .searching
        setPanel(.reading(hint: nil))
    }

    private func refreshBoard(_ code: String) async {
        do {
            let board = try await service.board(forStopCode: code)
            guard activeStopCode == code, !Task.isCancelled else { return }
            setPanel(.board(board))
        } catch {
            guard activeStopCode == code, !Task.isCancelled else { return }
            setPanel(.failure(stopCode: code, message: error.localizedDescription))
        }
    }

    private func setPanel(_ content: PanelContent) {
        guard content != panelContent else { return }
        panelContent = content
        onPanelContentChange?(content)
    }
}
