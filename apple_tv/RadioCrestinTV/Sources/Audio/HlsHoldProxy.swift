import Foundation
import Network

/// A local HTTP proxy that keeps a player's live HLS requests waiting
/// through an internet outage, instead of letting them fail.
///
/// AVPlayer retries a live playlist that fails to load only for a while
/// (macOS 27: ~30 s after its first failure; an iPhone 13 on mobile data,
/// iOS 27: ~100 s), then gives up: it loads nothing more, however long the
/// network has been back, until its buffer runs dry, and then restarts at
/// the live point, skipping what the 2- or 5-minute offset kept. No call
/// the app can make wakes it up. Through this proxy it never sees the
/// outage: a request that fails upstream is held, retried, and answered
/// with the origin's fresh response once the network is back. Measured on
/// the Mac with the iPhone app's proxy, which this one ports
/// (`lib/services/hls_hold_proxy.dart`): 100, 150 and 280 s outages played
/// through without a stall, the player loading the next segment within
/// ~0.2 s of the network returning. On the TV the player keeps 150 or
/// 330 s ahead (2- or 5-minute offset), so outages up to that long are
/// inaudible.
///
/// A held request is never failed on purpose while its player may still
/// want it: each one closed without a response counts towards the same
/// give-up (measured: three such closes 30 s apart, and AVPlayer silently
/// stopped loading).
///
/// `wrap` maps an upstream URL of an allowed host to
/// `http://127.0.0.1:<port>/<session>/<scheme>/<host[:port]><path>?<query>`.
/// The query is kept, and the relative segment URIs of a playlist then
/// resolve through the proxy too; an absolute or root-relative URI of an
/// allowed host in a playlist is rewritten to go through it.
///
/// Every player load is a session (`beginSession`). A request that fails
/// upstream at the network level is held only for the current session,
/// once it is established (a 2xx of it was answered): a new load while
/// offline fails at once, as it would without the proxy, so the engine's
/// retries and MP3 fallback keep working. That also holds while the
/// internet is known to work: the origin out of this device's reach (a DNS
/// or routing fault, a network that lies about its internet) is ridden out
/// from the buffer the same way, and should it outlast the buffer, the
/// engine's stall handling takes over, as without the proxy. An HTTP
/// status, an error one included, is the origin answering: relayed at
/// once, never held.
///
/// Threading: thread-safe. All its state lives on a private serial queue,
/// never the main thread; the public methods hop onto it. `onEvent` is
/// called on another private serial queue, in order, so that it may call
/// the proxy back.
final class HlsHoldProxy: @unchecked Sendable {
    /// The timings and limits of the proxy.
    struct Timings: Equatable, Sendable {
        /// How often a held request tries the origin again. The internet
        /// coming back (`networkRestored`) or another network
        /// (`networkChanged`) retries at once.
        var retryInterval: TimeInterval = 2

        /// The longest a request is held: a bit more than the player's
        /// longest forward buffer (330 s with the 5-minute offset), all an
        /// outage can be ridden out with. On the Mac, AVPlayer itself gave
        /// up on a request held for ~300 s.
        var maxHold: TimeInterval = 340

        /// The longest an upstream connection may take to open: DNS, TCP
        /// and TLS. See `UpstreamAttempt` for how the three timeouts map
        /// onto URLSession.
        var connectTimeout: TimeInterval = 5

        /// The longest the origin may take to send its response headers.
        var responseTimeout: TimeInterval = 10

        /// The longest the origin may pause while it sends a body.
        var bodyIdleTimeout: TimeInterval = 10

        /// The longest a player may take to send its request head over a
        /// connection it opened. AVPlayer sends it at once; this only frees
        /// a connection left idle.
        var requestHeadTimeout: TimeInterval = 10
    }

    /// Why a held request ended.
    enum HoldEnd: String, Sendable {
        /// The origin answered: the client got its (fresh) response.
        case answered
        /// A new session began (`beginSession`): the request's player has
        /// been replaced. Closed without a response.
        case released
        /// The client closed the connection: its player was stopped or
        /// gave up.
        case clientGone
        /// Held for `Timings.maxHold`: closed without a response.
        case maxHold
        /// The proxy was stopped (`stop`).
        case stopped
    }

    /// A notable moment, for the log: never one per normal request.
    /// `resource` is the last path segment of the upstream URL
    /// (`index-5m.m3u8`, a segment), `session` the request's.
    enum Event: CustomStringConvertible, Sendable {
        /// The proxy listens on `port`.
        case serverStarted(port: UInt16)
        /// The listening socket closed without `stop`: an error, the
        /// system reclaiming it, or `ensureRunning` finding it deaf.
        /// `ensureRunning` starts it again.
        case serverClosed(port: UInt16, error: Error?)
        /// A request failed upstream at the network level and is now held.
        case holdStarted(resource: String, session: Int, error: Error)
        /// Another try of a held request failed; `attempts` so far.
        case holdRetryFailed(
            resource: String, session: Int, attempts: Int, error: Error
        )
        /// A held request ended after `held` seconds and `attempts` tries;
        /// `status` is the one the client got when `end` is `.answered`.
        case holdEnded(
            resource: String, session: Int, held: TimeInterval,
            attempts: Int, end: HoldEnd, status: Int?
        )
        /// A request failed upstream at the network level and was failed at
        /// once (closed without a response): its session is not the
        /// current one, or has loaded nothing yet.
        case failedFast(resource: String, session: Int, error: Error)
        /// Something unexpected; the request concerned was failed.
        case internalError(Error)

        var description: String {
            switch self {
            case .serverStarted(let port):
                return "serverStarted port=\(port)"
            case .serverClosed(let port, let error):
                let reason = error.map {
                    " error=\(HlsHoldProxy.describe($0))"
                }
                return "serverClosed port=\(port)\(reason ?? "")"
            case .holdStarted(let resource, let session, let error):
                return "holdStarted \(resource) session=\(session)"
                    + " error=\(HlsHoldProxy.describe(error))"
            case .holdRetryFailed(
                let resource, let session, let attempts, let error
            ):
                return "holdRetryFailed \(resource) session=\(session)"
                    + " attempts=\(attempts)"
                    + " error=\(HlsHoldProxy.describe(error))"
            case .holdEnded(
                let resource, let session, let held, let attempts, let end,
                let status
            ):
                return "holdEnded \(resource) session=\(session)"
                    + " held=\(String(format: "%.1f", held))s"
                    + " attempts=\(attempts) end=\(end.rawValue)"
                    + (status.map { " status=\($0)" } ?? "")
            case .failedFast(let resource, let session, let error):
                return "failedFast \(resource) session=\(session)"
                    + " error=\(HlsHoldProxy.describe(error))"
            case .internalError(let error):
                return "internalError error=\(HlsHoldProxy.describe(error))"
            }
        }
    }

    /// The proxy's own failures, as events report them.
    enum ProxyError: Error, CustomStringConvertible {
        /// `ensureRunning` could not connect to the listening socket.
        case notAccepting
        /// A body over `HlsHoldProxy.maxBodyBytes`.
        case bodyTooLarge(limit: Int)
        /// The upstream answer was not an HTTP response.
        case notHTTP

        var description: String {
            switch self {
            case .notAccepting: return "listener not accepting"
            case .bodyTooLarge(let limit): return "body over \(limit) bytes"
            case .notHTTP: return "not an HTTP response"
            }
        }
    }

    /// The address the proxy listens on.
    static let loopbackHost = "127.0.0.1"

    /// The largest upstream body the proxy reads. HLS bodies are some tens
    /// of kilobytes; this only bounds the memory a wrong URL (an endless
    /// MP3 stream on an allowed host) can take before its request fails.
    static let maxBodyBytes = 16 * 1024 * 1024

    /// The request headers that go upstream. Accept-Encoding is the
    /// proxy's own (see `Exchange.upstreamRequest`); hop-by-hop ones stay
    /// on the loopback leg.
    static let forwardedRequestHeaders: Set<String> = [
        "user-agent",
        "accept",
        "accept-language",
        "range",
        "if-range",
        "if-none-match",
        "if-modified-since",
        "if-match",
        "if-unmodified-since",
        "x-playback-session-id",
        "cache-control",
        "pragma",
    ]

    /// The response headers relayed to the player, Location (mapped
    /// through the proxy) and Content-Length (computed) aside.
    static let relayedResponseHeaders = [
        "Content-Type",
        "Content-Range",
        "Accept-Ranges",
        "Cache-Control",
        "Expires",
        "Last-Modified",
        "ETag",
        "Date",
        "Age",
    ]

    /// How long `ensureRunning` waits for its connection to the listener.
    /// A loopback connection opens in well under a millisecond.
    private static let probeTimeout: TimeInterval = 1

    /// How long a restart waits for a closed listener to let go of its
    /// port before it binds anyway. Network.framework reports a cancelled
    /// listener within milliseconds.
    private static let listenerReleaseTimeout: TimeInterval = 1

    /// Pause before binding the previous port a second time, in case its
    /// socket is still being let go.
    private static let portRetryDelay: TimeInterval = 0.05

    let timings: Timings
    /// Lowercase.
    let allowedHosts: Set<String>
    let queue = DispatchQueue(label: "ro.radiocrestin.tv.hls-hold-proxy")

    private let onEvent: ((Event) -> Void)?
    private let eventQueue = DispatchQueue(
        label: "ro.radiocrestin.tv.hls-hold-proxy.events"
    )
    private let queueKey = DispatchSpecificKey<Bool>()
    private let upstreamConfiguration: URLSessionConfiguration
    /// URLSession's delegate calls, on `queue`.
    private let upstreamDelegateQueue = OperationQueue()

    // Everything below is used on `queue` only.

    private var listener: NWListener?
    private var listeningPort: UInt16?
    /// The port of the last listener, preferred by the next start so that
    /// the URLs handed out keep working.
    private var lastPort: UInt16?
    /// Listeners cancelled whose cancellation has not been reported yet:
    /// their port may not be free.
    private var closingListeners = Set<ObjectIdentifier>()
    private var listenersReleasedWaiters: [() -> Void] = []
    /// The start in flight, if any, and those waiting for it.
    private var activeBind: Int?
    private var binds = 0
    private var startWaiters: [(Bool) -> Void] = []
    /// Bumped by `stop`, so that what was under way before it does not
    /// outlive it.
    private var stops = 0

    private var currentSession = 0
    private var sessionEstablished = false
    private var sessionRequested = false
    private var sessionAnswered = false

    private var upstream: URLSession?
    private var upstreamGeneration = 0
    private var exchanges: [Int: Exchange] = [:]
    private var exchangeCount = 0

    /// `allowedHosts`: the only upstream hosts the proxy fetches from.
    /// `onEvent`: the notable moments, for the log (see the threading note
    /// on the type).
    init(
        allowedHosts: Set<String>,
        timings: Timings = Timings(),
        onEvent: ((Event) -> Void)? = nil
    ) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.timings = timings
        self.onEvent = onEvent
        upstreamConfiguration = Self.upstreamConfiguration(timings: timings)
        queue.setSpecific(key: queueKey, value: true)
        upstreamDelegateQueue.underlyingQueue = queue
        upstreamDelegateQueue.maxConcurrentOperationCount = 1
    }

    deinit {
        // Nothing else holds the proxy now, so its state is safe to touch
        // here: what is still connected must not hang on forever.
        stopNow()
    }

    // MARK: Public API

    /// The port it listens on; nil while it does not.
    var port: UInt16? { onQueue { listeningPort } }

    /// Whether `url` is one the proxy fetches: http(s), of an allowed host.
    func allows(_ url: URL) -> Bool {
        Self.allows(url, allowedHosts: allowedHosts)
    }

    /// Starts listening on the loopback interface. Restarted, it binds the
    /// port it had before when it can, so that the URLs it handed out keep
    /// working. Never throws: false when it cannot listen.
    func start() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.startListening { continuation.resume(returning: $0) }
            }
        }
    }

    /// Starts the proxy unless it listens and accepts connections. tvOS may
    /// reclaim a suspended app's listening socket without a word, so a
    /// running listener is checked with a connection to it (well under a
    /// millisecond on the loopback interface).
    func ensureRunning() async -> Bool {
        let running: (listener: NWListener, port: UInt16)? = onQueue {
            guard let listener, let listeningPort else { return nil }
            return (listener, listeningPort)
        }
        if let running {
            if await accepts(port: running.port) { return true }
            onQueue {
                listenerLost(running.listener, error: ProxyError.notAccepting)
            }
        }
        return await start()
    }

    /// Stops listening, fails every request in flight (closes it without a
    /// response) and drops the upstream connections. `start` may follow.
    func stop() {
        onQueue { stopNow() }
    }

    /// Starts a session, for a new player load, and returns it. The
    /// requests still held for an older session are closed without a
    /// response.
    @discardableResult
    func beginSession() -> Int {
        onQueue {
            currentSession += 1
            sessionEstablished = false
            sessionRequested = false
            sessionAnswered = false
            for exchange in Array(exchanges.values)
            where exchange.isHeld && exchange.target.session != currentSession {
                exchange.cancel(.released)
            }
            return currentSession
        }
    }

    /// Whether the origin answered a request of `session`, the current
    /// one, with any status: the way through the proxy works. A load
    /// through the proxy that failed without that may have failed for the
    /// proxy's own sake.
    func originAnswered(session: Int) -> Bool {
        onQueue { session == currentSession && sessionAnswered }
    }

    /// Whether a request of `session`, the current one, went upstream to
    /// the origin. A load through the proxy that is still waiting without
    /// that never got past the proxy: the proxy holds it up, not the
    /// origin.
    func originRequested(session: Int) -> Bool {
        onQueue { session == currentSession && sessionRequested }
    }

    /// The proxy's URL for `upstream` in `session`; nil when the proxy does
    /// not listen or `upstream` is not one it fetches (see `allows`).
    func wrap(_ upstream: URL, session: Int) -> URL? {
        guard let port, allows(upstream),
              let path = Self.proxyPath(for: upstream, session: session)
        else { return nil }
        return URL(string: "http://\(Self.loopbackHost):\(port)\(path)")
    }

    /// Whether `proxyURL`, from `wrap`, still reaches the proxy: it listens
    /// on that URL's port. After a restart on another port, what was
    /// loaded through the old one must be loaded again.
    func serves(_ proxyURL: URL) -> Bool {
        guard let port,
              let components = URLComponents(
                  url: proxyURL, resolvingAgainstBaseURL: true
              )
        else { return false }
        return components.host == Self.loopbackHost
            && components.port == Int(port)
    }

    /// The internet came back: the held requests try again at once, on new
    /// connections (the pooled ones may belong to the network that left).
    /// Requests in flight that are not held finish on theirs.
    func networkRestored() {
        onQueue {
            renewConnections()
            for exchange in Array(exchanges.values) where exchange.isHeld {
                exchange.retryNow()
            }
        }
    }

    /// The device moved to another network (Wi-Fi and Ethernet): the
    /// requests in flight on the one it left would hang until their
    /// timeouts. They are cut, so that each tries again at once on a new
    /// connection, as CFNetwork does: a request not held yet through its
    /// immediate retry, a held one through a retry now.
    func networkChanged() {
        onQueue {
            let left = upstream
            // First, so that the tries started below open new connections.
            upstream = nil
            for exchange in Array(exchanges.values) {
                exchange.networkChanged()
            }
            left?.invalidateAndCancel()
        }
    }

    /// Closes the listening socket as tvOS reclaiming it would, for tests.
    /// Requests in flight carry on: their connections are their own.
    func debugCloseListener() {
        onQueue {
            guard let listener else { return }
            listenerLost(listener, error: nil)
        }
    }

    /// A short description of a failure, for the log.
    static func describe(_ error: Error) -> String {
        let text: String
        if let error = error as? ProxyError {
            text = error.description
        } else {
            let error = error as NSError
            text = "\(error.domain) \(error.code): "
                + error.localizedDescription
        }
        return text.count > 160 ? String(text.prefix(160)) : text
    }

    /// Whether a try failed for want of a network (no route, reset, TLS, a
    /// timeout), which a hold may ride out; anything else is a fault.
    static func isNetworkFailure(_ error: Error) -> Bool {
        switch error {
        case let error as URLError:
            // Cancelled is the proxy's own doing; a bad URL never heals.
            return ![.cancelled, .badURL, .unsupportedURL].contains(error.code)
        case is POSIXError, is NWError:
            return true
        default:
            return (error as NSError).domain == NSPOSIXErrorDomain
        }
    }

    // MARK: For the exchanges

    func emit(_ event: Event) {
        guard let onEvent else { return }
        eventQueue.async { onEvent(event) }
    }

    func mayHold(session: Int) -> Bool {
        session == currentSession && sessionEstablished
    }

    func markEstablished(session: Int) {
        if session == currentSession { sessionEstablished = true }
    }

    func markRequested(session: Int) {
        if session == currentSession { sessionRequested = true }
    }

    func markAnswered(session: Int) {
        if session == currentSession { sessionAnswered = true }
    }

    func exchangeFinished(_ exchange: Exchange) {
        exchanges[exchange.id] = nil
    }

    /// The URLSession upstream requests go through, and its generation. A
    /// new one is a new connection pool: replacing it renews connections.
    func upstreamSession() -> (session: URLSession, generation: Int) {
        if let upstream { return (upstream, upstreamGeneration) }
        let session = URLSession(
            configuration: upstreamConfiguration,
            delegate: nil,
            delegateQueue: upstreamDelegateQueue
        )
        upstream = session
        upstreamGeneration += 1
        return (session, upstreamGeneration)
    }

    /// Drops the pooled upstream connections, so that the next requests
    /// open new ones: one opened on a network just left would hang.
    /// Requests in flight finish on theirs.
    func renewConnections() {
        upstream?.finishTasksAndInvalidate()
        upstream = nil
    }

    /// After a failure on the session of `generation`, the next try opens
    /// a new connection: a pooled one may be dead (network change), and the
    /// pool may hold more of them.
    func renewConnections(afterFailureOn generation: Int) {
        if generation == upstreamGeneration { renewConnections() }
    }

    // MARK: Requests

    private func accept(_ connection: NWConnection) {
        let client = ClientConnection(
            connection: connection,
            queue: queue,
            headTimeout: timings.requestHeadTimeout,
            acceptedAtStop: stops
        )
        client.start { [weak self, weak client] head in
            guard let self, let client else { return }
            self.handle(head, from: client)
        }
    }

    private func handle(_ head: RequestHead, from client: ClientConnection) {
        guard client.acceptedAtStop == stops else { return client.abort() }
        guard let target = Self.target(
                  ofRequestTarget: head.target, allowedHosts: allowedHosts
              )
        else { return client.respondEmpty(status: 404) }
        guard head.method == "GET" || head.method == "HEAD" else {
            return client.respondEmpty(
                status: 405,
                headers: [HeaderField(name: "Allow", value: "GET, HEAD")]
            )
        }
        exchangeCount += 1
        let exchange = Exchange(
            id: exchangeCount,
            proxy: self,
            client: client,
            target: target,
            method: head.method,
            headers: head.headers
        )
        exchanges[exchange.id] = exchange
        client.onLeave = { [weak exchange] in exchange?.cancel(.clientGone) }
        exchange.run()
    }

    // MARK: Listener

    private func startListening(_ completion: @escaping (Bool) -> Void) {
        if listener != nil { return completion(true) }
        startWaiters.append(completion)
        guard activeBind == nil else { return }
        binds += 1
        let bind = binds
        activeBind = bind
        afterClosingListenersReleased { [weak self] in
            self?.bindPreferredPort { listener in
                guard let self else { return }
                if let listener { return self.finishStart(bind, listener) }
                self.bindLoopback(port: 0) { self.finishStart(bind, $0) }
            }
        }
    }

    private func finishStart(_ bind: Int, _ bound: NWListener?) {
        guard bind == activeBind else {
            // Stopped while it bound.
            if let bound { closeListener(bound) }
            return
        }
        activeBind = nil
        if let bound, let port = bound.port?.rawValue {
            listener = bound
            listeningPort = port
            lastPort = port
            emit(.serverStarted(port: port))
        } else if let bound {
            closeListener(bound)
        }
        let waiters = startWaiters
        startWaiters = []
        let started = listener != nil
        waiters.forEach { $0(started) }
    }

    /// A listener on the port the proxy had before, so that the URLs it
    /// handed out keep working; nil when there was none, or it is taken.
    private func bindPreferredPort(
        _ completion: @escaping (NWListener?) -> Void
    ) {
        guard let port = lastPort else { return completion(nil) }
        bindLoopback(port: port) { [weak self] listener in
            guard listener == nil, let self else { return completion(listener) }
            // Once more, in case the socket is still being let go.
            self.queue.asyncAfter(deadline: .now() + Self.portRetryDelay) {
                self.bindLoopback(port: port, completion: completion)
            }
        }
    }

    /// A listener on `port` of the loopback interface (0: any free one),
    /// once it is ready; nil when that port is taken, or nothing can listen
    /// (then reported).
    private func bindLoopback(
        port: UInt16,
        completion: @escaping (NWListener?) -> Void
    ) {
        let parameters = NWParameters.tcp
        // SO_REUSEADDR: the connections the proxy closed linger in
        // TIME_WAIT on its port, which would otherwise keep a restart from
        // binding it again.
        parameters.allowLocalEndpointReuse = true
        // Bound to 127.0.0.1, so only this device can connect. Not
        // `acceptLocalOnly` as well: on the tvOS 27 simulator it dropped
        // every loopback connection unseen (the client's request went
        // unanswered and the connection closed), while macOS 27 let them
        // through.
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            if port == 0 { emit(.internalError(error)) }
            return completion(nil)
        }
        var pending: ((NWListener?) -> Void)? = completion
        // The handler holds the listener until it is cancelled.
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let done = pending
                pending = nil
                done?(listener)
            case .failed(let error), .waiting(let error):
                guard let done = pending else {
                    self?.listenerLost(listener, error: error)
                    return
                }
                pending = nil
                if port == 0 { self?.emit(.internalError(error)) }
                if let self {
                    self.closeListener(listener)
                } else {
                    listener.cancel()
                }
                done(nil)
            case .cancelled:
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
                self?.listenerLost(listener, error: nil, isCancelled: true)
                self?.listenerReleased(listener)
                let done = pending
                pending = nil
                done?(nil)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.accept(connection)
        }
        listener.start(queue: queue)
    }

    /// `lost`, if it is the current listener, no longer serves: an error,
    /// the system reclaiming it, or `ensureRunning` finding it deaf. It is
    /// forgotten, closed, and reported. Requests in flight carry on.
    private func listenerLost(
        _ lost: NWListener,
        error: Error?,
        isCancelled: Bool = false
    ) {
        guard lost === listener, let port = listeningPort else { return }
        listener = nil
        listeningPort = nil
        if !isCancelled { closeListener(lost) }
        emit(.serverClosed(port: port, error: error))
    }

    private func closeListener(_ closing: NWListener) {
        closingListeners.insert(ObjectIdentifier(closing))
        closing.cancel()
    }

    private func listenerReleased(_ released: NWListener) {
        guard closingListeners.remove(ObjectIdentifier(released)) != nil,
              closingListeners.isEmpty
        else { return }
        let waiters = listenersReleasedWaiters
        listenersReleasedWaiters = []
        waiters.forEach { $0() }
    }

    /// Runs `body` once the listeners being closed have let go of their
    /// port, or after `listenerReleaseTimeout` at the latest.
    private func afterClosingListenersReleased(
        _ body: @escaping () -> Void
    ) {
        guard !closingListeners.isEmpty else { return body() }
        var hasRun = false
        let runOnce = {
            guard !hasRun else { return }
            hasRun = true
            body()
        }
        listenersReleasedWaiters.append(runOnce)
        queue.asyncAfter(
            deadline: .now() + Self.listenerReleaseTimeout, execute: runOnce
        )
    }

    /// Whether a connection to `port` on the loopback interface opens.
    private func accepts(port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.probe(port: port) { continuation.resume(returning: $0) }
            }
        }
    }

    private func probe(port: UInt16, completion: @escaping (Bool) -> Void) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return completion(false)
        }
        let connection = NWConnection(
            host: .ipv4(.loopback), port: endpointPort, using: .tcp
        )
        var pending: ((Bool) -> Void)? = completion
        let finish = { (accepted: Bool) in
            guard let done = pending else { return }
            pending = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            done(accepted)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .failed, .waiting, .cancelled: finish(false)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.probeTimeout) {
            finish(false)
        }
    }

    // MARK: Stopping

    private func stopNow() {
        stops += 1
        activeBind = nil
        let waiters = startWaiters
        startWaiters = []
        if let listener {
            self.listener = nil
            listeningPort = nil
            closeListener(listener)
        }
        for exchange in Array(exchanges.values) {
            exchange.cancel(.stopped)
        }
        upstream?.invalidateAndCancel()
        upstream = nil
        waiters.forEach { $0(false) }
    }

    // MARK: Helpers

    /// Runs `body` on `queue`; at once when already on it, where
    /// `queue.sync` would deadlock.
    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return body() }
        return queue.sync(execute: body)
    }

    private static func upstreamConfiguration(
        timings: Timings
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        // A live playlist must never come from a cache.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // Fail at once while offline: the hold does the waiting.
        configuration.waitsForConnectivity = false
        // As AVPlayer marks its own requests.
        configuration.networkServiceType = .avStreaming
        configuration.timeoutIntervalForRequest =
            UpstreamAttempt.backstopTimeout(timings)
        return configuration
    }
}
