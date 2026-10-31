import Foundation
import Network

/// The loopback leg of the proxy: the player's HTTP/1.1 requests read off
/// an `NWConnection`, and the one response each gets.
extension HlsHoldProxy {
    /// One header line, request or response.
    struct HeaderField: Equatable {
        let name: String
        let value: String
    }

    /// The head of a player's request: its method, target and headers.
    struct RequestHead: Equatable {
        /// What parsing the bytes received so far gave.
        enum Parse: Equatable {
            /// The blank line that ends the head has not arrived yet.
            case incomplete
            /// Not an HTTP/1.x request head, or one over `maxBytes`.
            case malformed
            case complete(RequestHead)
        }

        let method: String
        /// The request target as sent: `/<session>/<scheme>/…?<query>`.
        let target: String
        /// In the order received, names lowercased.
        let headers: [HeaderField]

        /// The largest head accepted. AVPlayer's are well under a
        /// kilobyte; this only bounds what a stray client can make the
        /// proxy hold in memory.
        static let maxBytes = 16 * 1024

        private static let terminator = Data("\r\n\r\n".utf8)

        static func parse(_ buffer: Data) -> Parse {
            guard let end = buffer.firstRange(of: terminator) else {
                return buffer.count > maxBytes ? .malformed : .incomplete
            }
            let headBytes = buffer[buffer.startIndex..<end.lowerBound]
            guard headBytes.count <= maxBytes,
                  // A byte per character: header values are opaque bytes.
                  let text = String(data: headBytes, encoding: .isoLatin1)
            else { return .malformed }
            var lines = text.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(
                separator: " ", omittingEmptySubsequences: false
            )
            guard requestLine.count == 3,
                  !requestLine[0].isEmpty, !requestLine[1].isEmpty,
                  requestLine[2].hasPrefix("HTTP/1.")
            else { return .malformed }
            var headers: [HeaderField] = []
            for line in lines {
                guard let colon = line.firstIndex(of: ":"),
                      colon != line.startIndex
                else { return .malformed }
                let name = line[..<colon].lowercased()
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                headers.append(HeaderField(name: name, value: value))
            }
            return .complete(RequestHead(
                method: String(requestLine[0]),
                target: String(requestLine[1]),
                headers: headers
            ))
        }
    }

    /// A player's connection to the proxy, for one request: the proxy reads
    /// its head, writes its one response itself, and learns when it leaves.
    ///
    /// Every response closes the connection (`Connection: close`): that
    /// tells the proxy when a waiting client leaves (its side closes), and
    /// lets a request fail as a network error would, by closing without a
    /// response. A loopback connection per request costs next to nothing.
    ///
    /// Lives on the proxy's queue. A pending receive holds it until the
    /// connection ends, so nothing else needs to.
    final class ClientConnection {
        /// The proxy's stop count when it was accepted: a request whose head
        /// arrives after a `stop()` is not served.
        let acceptedAtStop: Int

        /// Called once, when the client closes the connection before the
        /// proxy is done with it: its player was stopped or gave up.
        var onLeave: (() -> Void)?

        private let connection: NWConnection
        private let queue: DispatchQueue
        /// How long the client may take to send its request head
        /// (`Timings.requestHeadTimeout`).
        private let headTimeoutInterval: TimeInterval
        private var buffer = Data()
        private var headTimeout: DispatchWorkItem?
        private var hasResponded = false
        private var isClosed = false

        /// How long the client gets to read a response and close its side
        /// before the proxy cuts the connection.
        private static let lingerInterval: TimeInterval = 5

        init(
            connection: NWConnection,
            queue: DispatchQueue,
            headTimeout: TimeInterval,
            acceptedAtStop: Int
        ) {
            self.connection = connection
            self.queue = queue
            self.headTimeoutInterval = headTimeout
            self.acceptedAtStop = acceptedAtStop
        }

        /// Starts reading the request; `onRequest` gets its head.
        func start(onRequest: @escaping (RequestHead) -> Void) {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.closed()
                default: break
                }
            }
            connection.start(queue: queue)
            let timeout = DispatchWorkItem { [weak self] in self?.abort() }
            headTimeout = timeout
            queue.asyncAfter(
                deadline: .now() + headTimeoutInterval, execute: timeout
            )
            receiveHead(onRequest)
        }

        /// Sends `status` with no body.
        func respondEmpty(status: Int, headers: [HeaderField] = []) {
            let length = HeaderField(name: "Content-Length", value: "0")
            respond(status: status, headers: headers + [length], body: Data())
        }

        /// Sends a whole response, then closes the connection once the
        /// client has read it. Content-Length, when due, is in `headers`.
        func respond(status: Int, headers: [HeaderField], body: Data) {
            guard !hasResponded, !isClosed else { return }
            hasResponded = true
            headTimeout?.cancel()
            var message = Self.head(status: status, headers: headers)
            message.append(body)
            connection.send(
                content: message,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil { return self.connection.cancel() }
                    self.queue.asyncAfter(
                        deadline: .now() + Self.lingerInterval
                    ) { [weak self] in self?.connection.cancel() }
                }
            )
        }

        /// Closes the connection without a response: the client sees a
        /// network error, as it would without the proxy.
        func abort() {
            guard !hasResponded else { return }
            hasResponded = true
            headTimeout?.cancel()
            connection.cancel()
        }

        // Captures `self` strongly on purpose: see the type's comment.
        private func receiveHead(_ onRequest: @escaping (RequestHead) -> Void) {
            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: RequestHead.maxBytes
            ) { [self] data, _, isComplete, error in
                guard !isClosed, !hasResponded else { return }
                if let data { buffer.append(data) }
                switch RequestHead.parse(buffer) {
                case .complete(let head):
                    headTimeout?.cancel()
                    buffer = Data()
                    watchForLeaving()
                    onRequest(head)
                case .malformed:
                    respondEmpty(status: 400)
                case .incomplete:
                    if isComplete || error != nil {
                        abort()
                    } else {
                        receiveHead(onRequest)
                    }
                }
            }
        }

        /// Reads (and drops) whatever else the client sends, to learn the
        /// moment it closes its side.
        private func watchForLeaving() {
            connection.receive(
                minimumIncompleteLength: 1, maximumLength: 64 * 1024
            ) { [self] _, _, isComplete, error in
                if isComplete || error != nil {
                    closed()
                } else if !isClosed {
                    watchForLeaving()
                }
            }
        }

        private func closed() {
            guard !isClosed else { return }
            isClosed = true
            headTimeout?.cancel()
            connection.cancel()
            let onLeave = self.onLeave
            self.onLeave = nil
            onLeave?()
        }

        private static func head(status: Int, headers: [HeaderField]) -> Data {
            var text = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
            for header in headers {
                // Values come from URLSession: never a line break, but one
                // would end the head early.
                let value = header.value.filter { $0 != "\r" && $0 != "\n" }
                text += "\(header.name): \(value)\r\n"
            }
            text += "Connection: close\r\n\r\n"
            return text.data(using: .isoLatin1, allowLossyConversion: true)
                ?? Data(text.utf8)
        }

        /// The standard phrase; players read only the code.
        private static func reasonPhrase(for status: Int) -> String {
            switch status {
            case 200: return "OK"
            case 204: return "No Content"
            case 206: return "Partial Content"
            case 301: return "Moved Permanently"
            case 302: return "Found"
            case 303: return "See Other"
            case 304: return "Not Modified"
            case 307: return "Temporary Redirect"
            case 308: return "Permanent Redirect"
            case 400: return "Bad Request"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 410: return "Gone"
            case 416: return "Range Not Satisfiable"
            case 429: return "Too Many Requests"
            case 500: return "Internal Server Error"
            case 502: return "Bad Gateway"
            case 503: return "Service Unavailable"
            case 504: return "Gateway Timeout"
            default: return "Status"
            }
        }
    }
}
