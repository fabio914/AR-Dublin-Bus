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
    /// Used to ask the server whether the feed has changed.
    private let session: URLSession
    private var timetable: StaticTimetable?
    private var loadTask: Task<StaticTimetable, Error>?
    private var phaseHandler: (@Sendable (TimetablePhase) -> Void)?

    init(
        feedURL: URL = TimetableStore.defaultFeedURL,
        directory: URL = TimetableStore.defaultDirectory,
        maximumAge: TimeInterval = 3 * 24 * 3600,
        session: URLSession = .shared
    ) {
        self.feedURL = feedURL
        self.directory = directory
        self.maximumAge = maximumAge
        self.session = session
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GTFS", isDirectory: true)
    }

    private var metadataURL: URL { directory.appendingPathComponent(Self.metadataFileName) }
    private var databaseURL: URL { directory.appendingPathComponent(Self.databaseFileName) }

    private var validatorURL: URL { directory.appendingPathComponent(Self.validatorFileName) }
    private var checkedURL: URL { directory.appendingPathComponent(Self.checkedFileName) }

    static let metadataFileName = "downloaded-at.txt"
    /// The feed's `ETag` (or `Last-Modified`) when it was downloaded.
    static let validatorFileName = "feed-validator.txt"
    /// When the server last confirmed that the downloaded feed is still the current one.
    static let checkedFileName = "checked-at.txt"
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

        // Keep using the cached copy, but look for a newer one in the background when stale.
        if !downloaded, let downloadedAt,
           Date.now.timeIntervalSince(max(downloadedAt, date(at: checkedURL) ?? .distantPast)) > maximumAge {
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

    /// Fetches a newer feed, if the server has one, while the current one stays in use. If that
    /// fails (offline, say), the current timetable is kept and the phase goes back to `.ready`.
    private func refreshInBackground() async {
        if await feedIsUnchanged() {
            // Nothing to download: check again in `maximumAge`.
            try? ISO8601DateFormatter().string(from: .now).write(to: checkedURL, atomically: true, encoding: .utf8)
            return
        }
        do {
            try await downloadAndBuild(inBackground: true)
            timetable = try await openDatabase()
        } catch {
            // Tried again the next time the app starts with a stale timetable.
        }
        report(.ready(downloadedAt: downloadDate() ?? .now))
    }

    /// Whether the server still publishes the feed that was downloaded, judging by its
    /// `ETag`/`Last-Modified`. False when that can't be told.
    private func feedIsUnchanged() async -> Bool {
        guard let stored = try? String(contentsOf: validatorURL, encoding: .utf8), !stored.isEmpty else { return false }
        var request = URLRequest(url: feedURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allowsConstrainedNetworkAccess = false
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        return Self.validator(of: http) == stored
    }

    fileprivate static func validator(of response: URLResponse?) -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        return http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "Last-Modified")
    }

    /// - Parameter inBackground: nobody asked for this download, so it's skipped in Low Data Mode.
    private func downloadAndBuild(inBackground: Bool = false) async throws {
        report(.downloading(progress: 0))
        let (zipURL, validator) = try await ProgressDownloader.download(feedURL, allowsConstrainedNetwork: !inBackground) { [weak self] fraction in
            Task { await self?.report(.downloading(progress: fraction)) }
        }
        defer { try? FileManager.default.removeItem(at: zipURL) }

        report(.extracting)
        let directory = self.directory
        // The CSV files are large (about 260 MB). They're extracted into the temporary folder,
        // which iOS empties by itself, and anything an interrupted build left behind is removed.
        Self.removeLeftoverStagingFolders(in: [Self.stagingParent, directory.deletingLastPathComponent()])
        let staging = Self.stagingParent
            .appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try await Task.detached(priority: .userInitiated) {
            try Self.extract(zipURL: zipURL, into: staging)
        }.value

        report(.indexing)
        try await Task.detached(priority: .userInitiated) {
            try Self.buildDatabase(in: staging, validator: validator)
            try Self.install(staging, at: directory)
        }.value
    }

    static let stagingPrefix = "GTFS-staging-"
    static var stagingParent: URL { FileManager.default.temporaryDirectory }

    /// Deletes staging folders left by builds that never finished (the app was killed, say).
    /// Earlier versions kept them next to the timetable, in Application Support.
    static func removeLeftoverStagingFolders(in parents: [URL]) {
        let fileManager = FileManager.default
        for parent in parents {
            let contents = (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
            for url in contents where url.lastPathComponent.hasPrefix(stagingPrefix) {
                try? fileManager.removeItem(at: url)
            }
        }
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
    private static func buildDatabase(in staging: URL, validator: String?) throws {
        try TimetableDatabaseBuilder.build(fromGTFS: staging, to: staging.appendingPathComponent(databaseFileName))
        for name in TimetableDatabaseBuilder.requiredFiles + TimetableDatabaseBuilder.optionalFiles {
            try? FileManager.default.removeItem(at: staging.appendingPathComponent(name))
        }
        try ISO8601DateFormatter().string(from: .now)
            .write(to: staging.appendingPathComponent(metadataFileName), atomically: true, encoding: .utf8)
        if let validator {
            try validator.write(to: staging.appendingPathComponent(validatorFileName), atomically: true, encoding: .utf8)
        }
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

    private func downloadDate() -> Date? { date(at: metadataURL) }

    private func date(at url: URL) -> Date? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func report(_ phase: TimetablePhase) {
        phaseHandler?(phase)
    }
}

/// Wraps a `URLSessionDownloadTask` so download progress can be reported.
private final class ProgressDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<(URL, String?), Error>?
    private var lastReported: Double = -1

    private init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    /// Downloads `url` to a temporary file. Also returns the response's `ETag`/`Last-Modified`.
    static func download(_ url: URL, allowsConstrainedNetwork: Bool,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws -> (URL, String?) {
        let downloader = ProgressDownloader(onProgress: onProgress)
        let configuration = URLSessionConfiguration.default
        configuration.allowsConstrainedNetworkAccess = allowsConstrainedNetwork
        let session = URLSession(configuration: configuration, delegate: downloader, delegateQueue: nil)
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
            finish(.success((destination, TimetableStore.validator(of: downloadTask.response))))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<(URL, String?), Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
