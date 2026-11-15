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

/// Downloads the NTA's static Dublin Bus GTFS feed, keeps it on disk and loads it.
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

    private var metadataURL: URL { directory.appendingPathComponent("downloaded-at.txt") }

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
        let haveFiles = downloadedAt != nil && StaticTimetable.requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }

        if forceDownload || !haveFiles {
            try await downloadAndExtract()
        }

        report(.indexing)
        let directory = self.directory
        let timetable = try await Task.detached(priority: .userInitiated) {
            try StaticTimetable.load(from: directory)
        }.value
        let date = downloadDate() ?? .now
        report(.ready(downloadedAt: date))

        // Keep using the cached copy, but fetch a newer one in the background when stale.
        if !forceDownload, haveFiles, let downloadedAt, Date.now.timeIntervalSince(downloadedAt) > maximumAge {
            Task { try? await self.refreshInBackground() }
        }
        return timetable
    }

    private func refreshInBackground() async throws {
        try await downloadAndExtract()
        let directory = self.directory
        let fresh = try await Task.detached(priority: .utility) { try StaticTimetable.load(from: directory) }.value
        timetable = fresh
        report(.ready(downloadedAt: downloadDate() ?? .now))
    }

    private func downloadAndExtract() async throws {
        report(.downloading(progress: 0))
        let zipURL = try await ProgressDownloader.download(feedURL) { [weak self] fraction in
            Task { await self?.report(.downloading(progress: fraction)) }
        }
        defer { try? FileManager.default.removeItem(at: zipURL) }

        report(.extracting)
        let directory = self.directory
        let metadataURL = self.metadataURL
        try await Task.detached(priority: .userInitiated) {
            try Self.extract(zipURL: zipURL, into: directory)
            try ISO8601DateFormatter().string(from: .now).write(to: metadataURL, atomically: true, encoding: .utf8)
        }.value
    }

    /// Extracts only the files the app needs (skipping e.g. the large `shapes.txt`)
    /// into a staging folder, then swaps it into place.
    private static func extract(zipURL: URL, into directory: URL) throws {
        let fileManager = FileManager.default
        let staging = directory.deletingLastPathComponent()
            .appendingPathComponent("GTFS-staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let archive = try Archive(url: zipURL, accessMode: .read)
        for name in StaticTimetable.requiredFiles + StaticTimetable.optionalFiles {
            let entry = archive[name] ?? archive.first { $0.path.hasSuffix("/" + name) }
            guard let entry else {
                if StaticTimetable.requiredFiles.contains(name) { throw TimetableError.missingFile(name) }
                continue
            }
            _ = try archive.extract(entry, to: staging.appendingPathComponent(name), skipCRC32: true)
        }

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
