import Foundation
@testable import ARDublinBus

/// Answers requests from memory, per URL.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [URL: Result<Response, URLError>] = [:]
    nonisolated(unsafe) private static var counts: [URL: Int] = [:]

    static func setResponse(_ response: Result<Response, URLError>, for url: URL) {
        lock.withLock { responses[url] = response }
    }

    static func requestCount(for url: URL) -> Int {
        lock.withLock { counts[url] ?? 0 }
    }

    static func resetRequestCount(for url: URL) {
        lock.withLock { counts[url] = 0 }
    }

    /// The realtime endpoint's response and request count.
    static var response: Result<(Int, Data), URLError> {
        get { fatalError("write-only") }
        set { setResponse(newValue.map { Response(status: $0.0, body: $0.1) }, for: RealtimeClient.endpoint) }
    }

    static var requests: Int {
        get { requestCount(for: RealtimeClient.endpoint) }
        set { resetRequestCount(for: RealtimeClient.endpoint) }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let result = Self.lock.withLock { () -> Result<Response, URLError> in
            Self.counts[url, default: 0] += 1
            return Self.responses[url] ?? .failure(URLError(.notConnectedToInternet))
        }
        switch result {
        case .success(let stub):
            let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: nil, headerFields: stub.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
