import Foundation
import ZIPFoundation

enum TimetablePhase: Equatable, Sendable {
    case idle
    case downloading(progress: Double)
    case extracting
    case indexing
    case ready(downloadedAt: Date)
    case failed(message: String)
}

/// Downloads the NTA's static Dublin Bus GTFS feed, converts it into the timetable
/// database (see `TimetableDatabaseBuilder`) and opens it.
///
/// The realtime (GTFS-R) trip IDs refer to this schedule, so it is refreshed
/// when older than `maximumAge`.
actor TimetableStore {
    /// Published by the NTA at https://www.transportforireland.ie/transitData/PT_Data.html
    static let defaultFeedURL = URL(string: "https://www.transportforireland.ie/transitData/Data/GTFS_Dublin_Bus.zip")!

    private let feedURL: URL
    private let directory: URL
    private let maximumAge: TimeInterval
    private var timetable: StaticTimetable?
    private var loadTask: Task<StaticTimetable, Error>?
    private var phaseHandler: (@Sendable (TimetablePhase) -> Void)?

    init(
        feedURL: URL = TimetableStore.defaultFeedURL,
        directory: URL = TimetableStore.defaultDirectory,
        maximumAge: TimeInterval = 3 * 24 * 3600
    ) {
        self.feedURL = feedURL
        self.directory = directory
        self.maximumAge = maximumAge
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GTFS", isDirectory: true)
    }

    private var metadataURL: URL { directory.appendingPathComponent(Self.metadataFileName) }
    private var databaseURL: URL { directory.appendingPathComponent(Self.databaseFileName) }

    static let metadataFileName = "downloaded-at.txt"
    static let databaseFileName = "timetable.sqlite"

    func setPhaseHandler(_ handler: @escaping @Sendable (TimetablePhase) -> Void) {
        phaseHandler = handler
    }

    /// Returns the loaded timetable, downloading it first if necessary.
    func loadedTimetable() async throws -> StaticTimetable {
        if let timetable { return timetable }
        if let loadTask { return try await loadTask.value }

        let task = Task { try await self.load(forceDownload: false) }
        loadTask = task
        defer { loadTask = nil }
        do {
            let result = try await task.value
            timetable = result
            return result
        } catch {
            report(.failed(message: error.localizedDescription))
            throw error
        }
    }

    /// Downloads a fresh copy of the feed and swaps it in.
    func refresh() async throws -> StaticTimetable {
        if let loadTask { _ = try? await loadTask.value }
        let task = Task { try await self.load(forceDownload: true) }
        loadTask = task
        defer { loadTask = nil }
        do {
            let result = try await task.value
            timetable = result
            return result
        } catch {
            if timetable != nil, let date = downloadDate() { report(.ready(downloadedAt: date)) }
            else { report(.failed(message: error.localizedDescription)) }
            throw error
        }
    }

    private func load(forceDownload: Bool) async throws -> StaticTimetable {
        let downloadedAt = downloadDate()
        let haveDatabase = downloadedAt != nil && FileManager.default.fileExists(atPath: databaseURL.path)
        var downloaded = false

        if forceDownload || !haveDatabase {
            try await downloadAndBuild()
            downloaded = true
        }

        report(.indexing)
        let timetable: StaticTimetable
        do {
            timetable = try await openDatabase()
        } catch _ where !downloaded {
            // Built by an older version of the app, or damaged: start again.
            try await downloadAndBuild()
            downloaded = true
            timetable = try await openDatabase()
        }
        report(.ready(downloadedAt: downloadDate() ?? .now))

        // Keep using the cached copy, but fetch a newer one in the background when stale.
        if !downloaded, let downloadedAt, Date.now.timeIntervalSince(downloadedAt) > maximumAge {
            Task { await self.refreshInBackground() }
        }
        return timetable
    }

    private func openDatabase() async throws -> StaticTimetable {
        let url = databaseURL
        return try await Task.detached(priority: .userInitiated) {
            try StaticTimetable.open(databaseAt: url)
        }.value
    }

    /// Fetches a newer feed while the current one stays in use. If that fails (offline, say),
    /// the current timetable is kept and the phase goes back to `.ready`.
    private func refreshInBackground() async {
        do {
            try await downloadAndBuild()
            timetable = try await openDatabase()
        } catch {
            // Tried again the next time the app starts with a stale timetable.
        }
        report(.ready(downloadedAt: downloadDate() ?? .now))
    }

    private func downloadAndBuild() async throws {
        report(.downloading(progress: 0))
        let zipURL = try await ProgressDownloader.download(feedURL) { [weak self] fraction in
            Task { await self?.report(.downloading(progress: fraction)) }
        }
        defer { try? FileManager.default.removeItem(at: zipURL) }

        report(.extracting)
        let directory = self.directory
        let staging = directory.deletingLastPathComponent()
            .appendingPathComponent("GTFS-staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try await Task.detached(priority: .userInitiated) {
            try Self.extract(zipURL: zipURL, into: staging)
        }.value

        report(.indexing)
        try await Task.detached(priority: .userInitiated) {
            try Self.buildDatabase(in: staging)
            try Self.install(staging, at: directory)
        }.value
    }

    /// Extracts only the files the timetable needs into `staging`.
    private static func extract(zipURL: URL, into staging: URL) throws {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let archive = try Archive(url: zipURL, accessMode: .read)
        for name in TimetableDatabaseBuilder.requiredFiles + TimetableDatabaseBuilder.optionalFiles {
            let entry = archive[name] ?? archive.first { $0.path.hasSuffix("/" + name) }
            guard let entry else {
                if TimetableDatabaseBuilder.requiredFiles.contains(name) { throw TimetableError.missingFile(name) }
                continue
            }
            _ = try archive.extract(entry, to: staging.appendingPathComponent(name), skipCRC32: true)
        }
    }

    /// Builds the database next to the CSV files, then deletes them: only the database is kept.
    private static func buildDatabase(in staging: URL) throws {
        try TimetableDatabaseBuilder.build(fromGTFS: staging, to: staging.appendingPathComponent(databaseFileName))
        for name in TimetableDatabaseBuilder.requiredFiles + TimetableDatabaseBuilder.optionalFiles {
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(name))
        }
        try ISO8601DateFormatter().string(from: .now)
            .write(to: staging.appendingPathComponent(metadataFileName), atomically: true, encoding: .utf8)
    }

    /// Swaps the staging folder into place.
    private static func install(_ staging: URL, at directory: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: staging, to: directory)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }

    private func downloadDate() -> Date? {
        guard let text = try? String(contentsOf: metadataURL, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func report(_ phase: TimetablePhase) {
        phaseHandler?(phase)
    }
}

/// Wraps a `URLSessionDownloadTask` so download progress can be reported.
private final class ProgressDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastReported: Double = -1

    private init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    static func download(_ url: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let downloader = ProgressDownloader(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            downloader.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if fraction - lastReported >= 0.01 || fraction >= 1 {
            lastReported = fraction
            onProgress(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        // The temporary file is deleted when this method returns, so move it now.
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("gtfs-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
