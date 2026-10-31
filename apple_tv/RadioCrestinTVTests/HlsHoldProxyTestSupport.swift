import Foundation
import Network
@testable import RadioCrestinTV

/// A value behind a lock, for state shared with a network queue.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    var current: Value { withValue { $0 } }
}

/// A fake HLS origin on the loopback interface whose network can go away.
///
/// It serves a live playlist (`version` tells a fresh answer from an old
/// one) and segments whose body names their path, or what `handler`
/// returns. Every response closes its connection.
final class FakeOrigin: @unchecked Sendable {
    /// How the origin treats the requests that arrive.
    enum Mode {
        case answering
        /// Cuts each connection once its request arrived, without an
        /// answer: the network is gone.
        case droppingConnections
        /// Leaves each request unanswered, as on a network whose packets
        /// vanish: the client waits until its timeout.
        case hanging
    }

    /// A request the origin got.
    struct Request {
        let method: String
        let path: String
        let query: String?
        /// Names lowercased.
        let headers: [String: String]
    }

    /// An answer; Content-Length is added unless given.
    struct Response {
        var status = 200
        var headers: [(String, String)] = []
        var body = Data()
        /// Cuts the connection after this many body bytes: a body that
        /// fails part way.
        var cutAfter: Int?
        /// Cuts the connection without an answer, as a network that is
        /// gone would.
        var dropsConnection = false

        static var dropped: Response { Response(dropsConnection: true) }
    }

    private struct State {
        var mode = Mode.answering
        var dropNext = 0
        var version = 1
        var handler: ((Request) -> Response?)?
        var requests: [Request] = []
        var open: [NWConnection] = []
    }

    let port: UInt16
    private let listener: NWListener
    private let queue: DispatchQueue
    private let state = Locked(State())

    private init(listener: NWListener, port: UInt16, queue: DispatchQueue) {
        self.listener = listener
        self.port = port
        self.queue = queue
    }

    /// An origin listening on a free loopback port.
    static func start() async throws -> FakeOrigin {
        let queue = DispatchQueue(label: "test.fake-origin")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: .any
        )
        let listener = try NWListener(using: parameters)
        let box = Locked<FakeOrigin?>(nil)
        listener.newConnectionHandler = { connection in
            guard let origin = box.current else { return connection.cancel() }
            origin.serve(connection)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation {
            continuation in
            let pending = Locked<CheckedContinuation<UInt16, Error>?>(
                continuation
            )
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, Error>
                switch state {
                case .ready: result = .success(listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error):
                    result = .failure(error)
                default: return
                }
                let waiting = pending.withValue { value in
                    defer { value = nil }
                    return value
                }
                waiting?.resume(with: result)
            }
            listener.start(queue: queue)
        }
        let origin = FakeOrigin(listener: listener, port: port, queue: queue)
        box.withValue { $0 = origin }
        return origin
    }

    var mode: Mode {
        get { state.withValue { $0.mode } }
        set { state.withValue { $0.mode = newValue } }
    }

    /// The next this many requests get their connection cut.
    var dropNext: Int {
        get { state.withValue { $0.dropNext } }
        set { state.withValue { $0.dropNext = newValue } }
    }

    /// The playlist's version, to tell a fresh answer from an old one.
    var version: Int {
        get { state.withValue { $0.version } }
        set { state.withValue { $0.version = newValue } }
    }

    /// Answers in place of the default playlists and segments; nil leaves
    /// the request unanswered.
    var handler: ((Request) -> Response?)? {
        get { state.withValue { $0.handler } }
        set { state.withValue { $0.handler = newValue } }
    }

    /// Every request it got, in order.
    var requests: [Request] { state.withValue { $0.requests } }

    func url(_ pathAndQuery: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)\(pathAndQuery)")!
    }

    func close() {
        listener.cancel()
        let open = state.withValue { state -> [NWConnection] in
            defer { state.open = [] }
            return state.open
        }
        open.forEach { $0.cancel() }
    }

    /// The default live playlist: one segment, named after the version.
    static func playlist(version: Int) -> String {
        "#EXTM3U\n"
            + "#EXT-X-VERSION:6\n"
            + "#EXT-X-MEDIA-SEQUENCE:\(version)\n"
            + "#EXTINF:6.0,\n"
            + "seg-\(version).ts\n"
    }

    // MARK: Serving

    private func serve(_ connection: NWConnection) {
        state.withValue { $0.open.append(connection) }
        connection.start(queue: queue)
        readHead(of: connection, buffer: Data())
    }

    private func readHead(of connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 64 * 1024
        ) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                return answer(request, on: connection)
            }
            if isComplete || error != nil { return connection.cancel() }
            readHead(of: connection, buffer: buffer)
        }
    }

    private enum Action {
        case drop
        case hang
        case respond(Response)
        case useHandler((Request) -> Response?)
    }

    private func answer(_ request: Request, on connection: NWConnection) {
        let action: Action = state.withValue { state in
            state.requests.append(request)
            switch state.mode {
            case .hanging:
                return .hang
            case .droppingConnections:
                return .drop
            case .answering:
                if state.dropNext > 0 {
                    state.dropNext -= 1
                    return .drop
                }
                if let handler = state.handler { return .useHandler(handler) }
                return .respond(
                    Self.defaultResponse(to: request, version: state.version)
                )
            }
        }
        switch action {
        case .drop:
            connection.cancel()
        case .hang:
            break
        case .respond(let response):
            send(response, for: request, on: connection)
        case .useHandler(let handler):
            guard let response = handler(request) else { return }
            if response.dropsConnection {
                connection.cancel()
            } else {
                send(response, for: request, on: connection)
            }
        }
    }

    private func send(
        _ response: Response,
        for request: Request,
        on connection: NWConnection
    ) {
        var head = "HTTP/1.1 \(response.status) Test\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        let hasLength = response.headers.contains {
            $0.0.lowercased() == "content-length"
        }
        if !hasLength {
            head += "Content-Length: \(response.body.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var message = Data(head.utf8)
        let body = request.method == "HEAD" ? Data() : response.body
        if let cut = response.cutAfter {
            message.append(body.prefix(cut))
            connection.send(
                content: message,
                completion: .contentProcessed { _ in connection.forceCancel() }
            )
            return
        }
        message.append(body)
        connection.send(
            content: message,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [queue] _ in
                // The client closes once it has read the response.
                queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
            }
        )
    }

    private static func defaultResponse(
        to request: Request,
        version: Int
    ) -> Response {
        if request.path.hasSuffix(".m3u8") {
            return Response(
                headers: [
                    ("Content-Type", "application/vnd.apple.mpegurl"),
                    ("Cache-Control", "no-store"),
                    ("ETag", "W/\"v\(version)\""),
                    ("Last-Modified", "Sat, 17 Oct 2026 08:44:00 GMT"),
                ],
                body: Data(playlist(version: version).utf8)
            )
        }
        let bytes = Data("segment \(request.path)".utf8)
        var headers = [
            ("Content-Type", "video/mp2t"),
            ("Accept-Ranges", "bytes"),
        ]
        if let range = request.headers["range"],
           let (from, to) = parseRange(range) {
            let contentRange = "bytes \(from)-\(to)/\(bytes.count)"
            headers.append(("Content-Range", contentRange))
            let part = bytes.subdata(in: from..<to + 1)
            return Response(status: 206, headers: headers, body: part)
        }
        return Response(headers: headers, body: bytes)
    }

    private static func parseRange(_ value: String) -> (Int, Int)? {
        guard value.hasPrefix("bytes=") else { return nil }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-")
        guard bounds.count == 2, let from = Int(bounds[0]),
              let to = Int(bounds[1])
        else { return nil }
        return (from, to)
    }

    private static func parse(_ buffer: Data) -> Request? {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)),
              let text = String(
                  data: buffer[..<end.lowerBound], encoding: .isoLatin1
              )
        else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return nil }
        let target = requestLine[1].split(
            separator: "?", maxSplits: 1, omittingEmptySubsequences: false
        )
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let value = line[line.index(after: colon)...]
            headers[line[..<colon].lowercased()] =
                value.trimmingCharacters(in: .whitespaces)
        }
        return Request(
            method: String(requestLine[0]),
            path: String(target[0]),
            query: target.count > 1 ? String(target[1]) : nil,
            headers: headers
        )
    }
}

// MARK: A stream AVPlayer plays

extension FakeOrigin {
    /// An on-demand playlist of `segments` segments of silent MP3, ~1 s
    /// each, named `seg-<n>.mp3`: what AVPlayer needs to get an item ready
    /// and play it.
    static func vodPlaylist(segments: Int) -> String {
        var playlist = "#EXTM3U\n"
            + "#EXT-X-VERSION:3\n"
            + "#EXT-X-TARGETDURATION:1\n"
            + "#EXT-X-MEDIA-SEQUENCE:0\n"
            + "#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<segments {
            playlist += "#EXTINF:0.993,\nseg-\(index).mp3\n"
        }
        return playlist + "#EXT-X-ENDLIST\n"
    }

    /// The answer of a stream AVPlayer plays: `vodPlaylist` for any
    /// playlist, its segments, and 404 for anything else.
    static func playableStream(
        _ request: Request,
        segments: Int = 60
    ) -> Response {
        let name = request.path.split(separator: "/").last ?? ""
        if name.hasSuffix(".m3u8") {
            return Response(
                headers: [("Content-Type", "application/vnd.apple.mpegurl")],
                body: Data(vodPlaylist(segments: segments).utf8)
            )
        }
        guard name.hasPrefix("seg-"), name.hasSuffix(".mp3"),
              let index = UInt64(name.dropFirst(4).dropLast(4))
        else { return Response(status: 404) }
        return Response(
            headers: [("Content-Type", "audio/mpeg")],
            // 0.993 s a segment, in 90 kHz ticks.
            body: silentMP3Segment(timestamp: index * 89_370)
        )
    }

    /// ~1 s of silent MPEG-1 Layer III (44.1 kHz, 128 kb/s, stereo): 38
    /// frames whose side information is all zeros, which decodes as
    /// silence. HLS packed audio starts with an ID3 tag carrying the
    /// segment's 90 kHz `timestamp`.
    static func silentMP3Segment(timestamp: UInt64) -> Data {
        var payload = Data("com.apple.streaming.transportStreamTimestamp".utf8)
        payload.append(0)
        withUnsafeBytes(of: timestamp.bigEndian) {
            payload.append(contentsOf: $0)
        }
        func syncSafe(_ value: Int) -> [UInt8] {
            [21, 14, 7, 0].map { UInt8((value >> $0) & 0x7F) }
        }
        var data = Data("ID3".utf8)
        data.append(contentsOf: [4, 0, 0] + syncSafe(10 + payload.count))
        data.append(contentsOf: Data("PRIV".utf8))
        data.append(contentsOf: syncSafe(payload.count) + [0, 0])
        data.append(payload)
        // MPEG-1 Layer III, no CRC, 128 kb/s, 44.1 kHz, no padding, stereo:
        // 144 * 128000 / 44100 = 417 bytes a frame.
        var frame = Data([0xFF, 0xFB, 0x90, 0x00])
        frame.append(Data(count: 417 - 4))
        for _ in 0..<38 { data.append(frame) }
        return data
    }
}

/// What a player got: the status, the headers and the body.
struct PlayerResponse {
    let status: Int
    let response: HTTPURLResponse
    let data: Data

    var body: String { String(decoding: data, as: UTF8.self) }

    func header(_ name: String) -> String? {
        response.value(forHTTPHeaderField: name)
    }
}

/// A player's HTTP client: URLSession, as AVPlayer's is, without a cache
/// and without following redirects.
final class TestPlayer: NSObject, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(
            configuration: configuration, delegate: self, delegateQueue: nil
        )
    }()

    func get(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:]
    ) async throws -> PlayerResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return PlayerResponse(
            status: http.statusCode, response: http, data: data
        )
    }

    func close() {
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// A bare TCP client: sends one request and reads the raw answer, or
/// leaves while it waits.
final class RawClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "test.raw-client")
    private let received = Locked((data: Data(), isClosed: false))

    init(port: UInt16) {
        connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    /// Connects and sends `request` (a whole request head).
    func send(_ request: String) {
        connection.start(queue: queue)
        connection.send(
            content: Data(request.utf8), completion: .contentProcessed { _ in }
        )
        receive()
    }

    /// What arrived so far, and whether the proxy closed the connection.
    var answer: (text: String, isClosed: Bool) {
        let value = received.current
        return (String(decoding: value.data, as: UTF8.self), value.isClosed)
    }

    /// Closes the connection: the player leaves.
    func leave() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 64 * 1024
        ) { [self] data, _, isComplete, error in
            received.withValue { value in
                if let data { value.data.append(data) }
                if isComplete || error != nil { value.isClosed = true }
            }
            if !isComplete, error == nil { receive() }
        }
    }
}

/// The proxy's events, as delivered on its event queue.
final class EventLog: @unchecked Sendable {
    private let events = Locked<[HlsHoldProxy.Event]>([])

    func record(_ event: HlsHoldProxy.Event) {
        events.withValue { $0.append(event) }
    }

    var all: [HlsHoldProxy.Event] { events.current }

    var holdStarts: [(resource: String, error: Error)] {
        all.compactMap {
            if case .holdStarted(let resource, _, let error) = $0 {
                return (resource, error)
            }
            return nil
        }
    }

    var holdRetryFailures: [Error] {
        all.compactMap {
            if case .holdRetryFailed(_, _, _, let error) = $0 { return error }
            return nil
        }
    }

    typealias HoldEnd = (
        end: HlsHoldProxy.HoldEnd, status: Int?, held: TimeInterval
    )

    var holdEnds: [HoldEnd] {
        all.compactMap {
            if case .holdEnded(_, _, let held, _, let end, let status) = $0 {
                return (end, status, held)
            }
            return nil
        }
    }

    var failedFastSessions: [Int] {
        all.compactMap {
            if case .failedFast(_, let session, _) = $0 { return session }
            return nil
        }
    }

    var internalErrors: [Error] {
        all.compactMap {
            if case .internalError(let error) = $0 { return error }
            return nil
        }
    }

    var serverStarts: Int {
        all.filter {
            if case .serverStarted = $0 { return true }
            return false
        }.count
    }

    var serverCloses: Int {
        all.filter {
            if case .serverClosed = $0 { return true }
            return false
        }.count
    }

    /// Everything but the server's start: what normal requests must not
    /// produce.
    var requestEvents: [HlsHoldProxy.Event] {
        all.filter {
            if case .serverStarted = $0 { return false }
            return true
        }
    }
}

/// Holds a loopback port, so that the proxy cannot bind it.
final class PortSquatter {
    private let descriptor: Int32

    /// Takes `port` once the proxy's closed listener has let go of it,
    /// waiting up to a second for that.
    static func take(port: UInt16) async throws -> PortSquatter {
        let deadline = Date().addingTimeInterval(1)
        while true {
            do {
                return try PortSquatter(port: port)
            } catch {
                guard Date() < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private init(port: UInt16) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        // Past the connections the proxy closed, which linger in TIME_WAIT
        // on the port; a listening socket still keeps the proxy out.
        var reuse: Int32 = 1
        setsockopt(
            fd, SOL_SOCKET, SO_REUSEADDR, &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let isListening = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 4) == 0
            }
        }
        guard isListening else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        descriptor = fd
    }

    deinit {
        close(descriptor)
    }
}

/// `data` as gzip: the deflate stream Foundation makes, with the gzip
/// header and trailer around it.
func gzipped(_ data: Data) throws -> Data {
    let deflated = try (data as NSData).compressed(using: .zlib) as Data
    var result = Data([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF])
    result.append(deflated)
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
        }
    }
    for value in [~crc, UInt32(truncatingIfNeeded: data.count)] {
        withUnsafeBytes(of: value.littleEndian) {
            result.append(contentsOf: $0)
        }
    }
    return result
}
