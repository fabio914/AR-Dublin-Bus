import Foundation
import WatchConnectivity

enum PhoneConnectionError: LocalizedError {
    case unsupported
    case notActivated
    case unreachable(details: String)
    case timedOut
    case emptyReply
    case other(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: "This watch can't talk to an iPhone."
        case .notActivated: "Still connecting to your iPhone. Try again in a moment."
        case .unreachable(let details): "Your iPhone isn't reachable. Keep it nearby with Bluetooth on. (\(details))"
        case .timedOut: "Your iPhone took too long to answer. Open the app on your iPhone once, then try again."
        case .emptyReply: "Your iPhone didn't send any stops."
        case .other(let message): message
        }
    }
}

/// Asks the iPhone app for nearby boards over WatchConnectivity.
///
/// Messages are sent even when `isReachable` is false: sending from the watch app
/// wakes the iPhone app in the background, which is what makes it reachable.
@MainActor
final class PhoneConnection: NSObject, WCSessionDelegate {
    private var activationWaiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func nearby(_ request: WatchNearbyRequest) async throws -> WatchNearbyResponse {
        guard WCSession.isSupported() else { throw PhoneConnectionError.unsupported }
        let session = WCSession.default

        if session.activationState != .activated {
            await waitForActivation(timeout: .seconds(5))
        }
        guard session.activationState == .activated else { throw PhoneConnectionError.notActivated }

        let data = try WatchMessageCoding.encode(request)
        let reply: Data
        do {
            reply = try await send(data, over: session)
        } catch WCError.notReachable {
            // The first message can race the iPhone app's background launch; try once more.
            try await Task.sleep(for: .seconds(2))
            do {
                reply = try await send(data, over: session)
            } catch WCError.notReachable {
                throw PhoneConnectionError.unreachable(details: Self.describe(session))
            }
        } catch WCError.messageReplyTimedOut {
            throw PhoneConnectionError.timedOut
        } catch let error as WCError {
            throw PhoneConnectionError.other("\(error.localizedDescription) (WatchConnectivity error \(error.code.rawValue))")
        }

        guard !reply.isEmpty else { throw PhoneConnectionError.emptyReply }
        return try WatchMessageCoding.decode(WatchNearbyResponse.self, from: reply)
    }

    private func send(_ data: Data, over session: WCSession) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            session.sendMessageData(data, replyHandler: { continuation.resume(returning: $0) },
                                    errorHandler: { continuation.resume(throwing: $0) })
        }
    }

    /// Waits for `activationDidComplete`, or `timeout`, whichever comes first.
    private func waitForActivation(timeout: Duration) async {
        let timer = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            resumeActivationWaiters()
        }
        await withCheckedContinuation { activationWaiters.append($0) }
        timer.cancel()
    }

    private func resumeActivationWaiters() {
        let waiters = activationWaiters
        activationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// Session state, shown with errors to help diagnose pairing problems.
    private static func describe(_ session: WCSession) -> String {
        "activated: \(session.activationState == .activated ? "yes" : "no"), "
            + "reachable: \(session.isReachable ? "yes" : "no"), "
            + "iPhone app installed: \(session.isCompanionAppInstalled ? "yes" : "no")"
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in resumeActivationWaiters() }
    }
}
