import Foundation
@testable import RadioCrestinTV

/// Answers the reviews API without the network, as the API does: 200 with
/// `data.submit_review` or `data.delete_review` reporting success, unless a
/// test serves another answer. Notes every request with its JSON body.
///
/// It answers every request its session sends, whatever the host, and the
/// tests point the service at a host that cannot resolve: no review can
/// reach the real API.
final class ReviewStubProtocol: URLProtocol {
    struct Request {
        let url: URL
        let method: String?
        let headers: [String: String]
        let body: [String: Any]
    }

    /// A host that never resolves (RFC 2606).
    static let baseURL = "https://reviews.invalid/api/v1"

    private static let lock = NSLock()
    private static var requests: [Request] = []
    private static var status = 200
    private static var answer: Data?
    private static var failure: URLError?
    private static var isHolding = false
    private static var held: [ReviewStubProtocol] = []

    /// A review service whose requests this stub answers, on behalf of
    /// `test-device`, reporting failures to `reportFailure`.
    static func service(
        reportFailure: @escaping ReviewService.FailureReporter = { _, _, _ in }
    ) -> ReviewService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReviewStubProtocol.self]
        return ReviewService(
            session: URLSession(configuration: configuration),
            baseURL: baseURL,
            userIdentifier: { "test-device" },
            reportFailure: reportFailure
        )
    }

    /// Answers with `status` and `body` instead of a success.
    static func serve(status: Int, body: String) {
        lock.withLock {
            self.status = status
            answer = Data(body.utf8)
        }
    }

    /// Fails the requests as with the API out of reach.
    static func failRequests(_ error: URLError) {
        lock.withLock { failure = error }
    }

    /// Holds every answer until `releaseAnswers()`, as an API slow to
    /// answer.
    static func holdAnswers() {
        lock.withLock { isHolding = true }
    }

    /// Gives the answers held, and answers at once from then on.
    static func releaseAnswers() {
        let waiting = lock.withLock {
            isHolding = false
            defer { held = [] }
            return held
        }
        waiting.forEach { $0.answer() }
    }

    /// Every request since the last `reset()`, in order.
    static var received: [Request] {
        lock.withLock { requests }
    }

    static func reset() {
        releaseAnswers()
        lock.withLock {
            requests = []
            status = 200
            answer = nil
            failure = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let data = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let isHeld = Self.lock.withLock {
            Self.requests.append(Request(
                url: url,
                method: request.httpMethod,
                headers: request.allHTTPHeaderFields ?? [:],
                body: body ?? [:]
            ))
            if Self.isHolding { Self.held.append(self) }
            return Self.isHolding
        }
        if !isHeld { answer() }
    }

    /// Answers the request: the failure or the answer a test serves, else
    /// the API's success.
    private func answer() {
        guard let url = request.url else { return }
        let (status, served, failure) = Self.lock.withLock {
            (Self.status, Self.answer, Self.failure)
        }
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        if let response {
            client?.urlProtocol(
                self, didReceive: response, cacheStoragePolicy: .notAllowed
            )
        }
        client?.urlProtocol(self, didLoad: served ?? Self.success(for: url))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The API's answer to a review it took.
    private static func success(for url: URL) -> Data {
        // `URL.path` drops the trailing slash.
        let isDelete = url.absoluteString.hasSuffix("/delete/")
        let field = isDelete ? "delete_review" : "submit_review"
        let typename = isDelete ? "DeleteReviewResponse" : "SubmitReviewResponse"
        return Data("""
        {"data":{"\(field)":{"__typename":"\(typename)","success":true}}}
        """.utf8)
    }

    /// URLSession hands a protocol the body as a stream.
    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Failures a review service reported, for a test to read.
final class ReportedFailures {
    struct Failure {
        let error: Error
        let context: String
        let extra: [String: Any]
    }

    private let lock = NSLock()
    private var failures: [Failure] = []

    var all: [Failure] { lock.withLock { failures } }

    func record(_ error: Error, _ context: String, _ extra: [String: Any]) {
        lock.withLock {
            failures.append(Failure(error: error, context: context, extra: extra))
        }
    }
}
