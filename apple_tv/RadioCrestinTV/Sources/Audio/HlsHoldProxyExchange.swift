import Foundation

extension HlsHoldProxy {
    /// One player request, from its arrival to its response or failure.
    ///
    /// It is tried upstream; a failed first try is tried again at once on
    /// a new connection; a network failure after that is held, for the
    /// current session once established, and failed at once otherwise (see
    /// `HlsHoldProxy`). Held, it is tried again every `retryInterval`, and
    /// at once when the network comes back or changes, until the origin
    /// answers, its session is replaced, the client leaves, `maxHold`
    /// passes, or the proxy stops.
    ///
    /// Lives on the proxy's queue: every method is called there.
    final class Exchange {
        private enum Stage {
            case firstTry
            /// The first try failed: the one retry on a new connection that
            /// any failure gets before the request is held or failed.
            case immediateRetry
            case holding
        }

        let id: Int
        let target: Target

        private weak var proxy: HlsHoldProxy?
        private let client: ClientConnection
        private let request: URLRequest
        private let timings: Timings
        private let queue: DispatchQueue

        private var stage = Stage.firstTry
        private var attempt: UpstreamAttempt?
        private var retryTimer: DispatchWorkItem?
        private var heldSince: DispatchTime?
        /// Upstream tries of the hold so far, the first two included.
        private var attempts = 0
        private var isFinished = false

        /// Whether the request is held (see `HlsHoldProxy`).
        var isHeld: Bool { stage == .holding && !isFinished }

        init(
            id: Int,
            proxy: HlsHoldProxy,
            client: ClientConnection,
            target: Target,
            method: String,
            headers: [HeaderField]
        ) {
            self.id = id
            self.proxy = proxy
            self.client = client
            self.target = target
            self.timings = proxy.timings
            self.queue = proxy.queue
            self.request = Self.upstreamRequest(
                for: target,
                method: method,
                headers: headers,
                timings: proxy.timings
            )
        }

        func run() {
            tryUpstream()
        }

        /// Ends the request for `reason`, closing it without a response; a
        /// try in flight is abandoned. Reported when it was held.
        func cancel(_ reason: HoldEnd) {
            guard !isFinished else { return }
            abandonAttempt()
            if stage == .holding { reportHoldEnd(reason, status: nil) }
            fail()
        }

        /// Tries a held request again at once: the network came back. A try
        /// in flight is abandoned, its connection perhaps on the network
        /// that left.
        func retryNow() {
            guard isHeld else { return }
            abandonAttempt()
            retryTimer?.cancel()
            retryTimer = nil
            retryUnlessHeldTooLong()
        }

        /// The device moved to another network: a held request tries again
        /// at once, and a try in flight that is not held yet is cut, as if
        /// its connection had dropped, so that it goes on to its retry on a
        /// new connection instead of hanging until its timeout.
        func networkChanged() {
            guard !isFinished else { return }
            if stage == .holding { return retryNow() }
            guard let attempt else { return }
            abandonAttempt()
            attemptEnded(.failure(
                URLError(.networkConnectionLost),
                generation: attempt.generation
            ))
        }

        // MARK: Tries

        private func tryUpstream() {
            guard let proxy else { return fail() }
            let upstream = proxy.upstreamSession()
            let session = target.session
            proxy.markRequested(session: session)
            let attempt = UpstreamAttempt(
                request: request,
                target: target,
                session: upstream.session,
                generation: upstream.generation,
                timings: timings,
                allowedHosts: proxy.allowedHosts,
                queue: queue,
                onHeaders: { [weak proxy] in
                    proxy?.markAnswered(session: session)
                },
                completion: { [weak self] outcome in
                    self?.attemptEnded(outcome)
                }
            )
            self.attempt = attempt
            attempt.start()
        }

        private func abandonAttempt() {
            attempt?.abandon()
            attempt = nil
        }

        private func attemptEnded(_ outcome: UpstreamAttempt.Outcome) {
            attempt = nil
            guard !isFinished else { return }
            switch outcome {
            case .response(let response):
                if stage == .holding {
                    attempts += 1
                    reportHoldEnd(.answered, status: response.status)
                }
                answer(response)
            case .failure(let error, let generation):
                tryFailed(error, generation: generation)
            }
        }

        private func tryFailed(_ error: Error, generation: Int) {
            switch stage {
            case .firstTry:
                // A pooled connection that died with a network change fails
                // at once: try again at once, on a new one, as CFNetwork
                // does.
                proxy?.renewConnections(afterFailureOn: generation)
                stage = .immediateRetry
                tryUpstream()
            case .immediateRetry:
                guard let proxy else { return fail() }
                if !HlsHoldProxy.isNetworkFailure(error) {
                    proxy.emit(.internalError(error))
                    fail()
                } else if !proxy.mayHold(session: target.session) {
                    proxy.emit(.failedFast(
                        resource: target.resource,
                        session: target.session,
                        error: error
                    ))
                    fail()
                } else {
                    startHold(after: error)
                }
            case .holding:
                attempts += 1
                proxy?.emit(.holdRetryFailed(
                    resource: target.resource,
                    session: target.session,
                    attempts: attempts,
                    error: error
                ))
                scheduleRetry()
            }
        }

        // MARK: The hold

        private func startHold(after error: Error) {
            stage = .holding
            heldSince = .now()
            // The first try and its immediate retry.
            attempts = 2
            proxy?.emit(.holdStarted(
                resource: target.resource,
                session: target.session,
                error: error
            ))
            scheduleRetry()
        }

        private var heldFor: TimeInterval {
            guard let heldSince else { return 0 }
            let nanoseconds = DispatchTime.now().uptimeNanoseconds
                - heldSince.uptimeNanoseconds
            return TimeInterval(nanoseconds) / 1_000_000_000
        }

        /// Waits for the next try: the retry interval, or what is left of
        /// `maxHold` when that is shorter.
        private func scheduleRetry() {
            let left = timings.maxHold - heldFor
            guard left > 0 else { return endHold(.maxHold) }
            let timer = DispatchWorkItem { [weak self] in
                guard let self, !self.isFinished else { return }
                self.retryTimer = nil
                self.retryUnlessHeldTooLong()
            }
            retryTimer = timer
            queue.asyncAfter(
                deadline: .now() + min(left, timings.retryInterval),
                execute: timer
            )
        }

        private func retryUnlessHeldTooLong() {
            if heldFor >= timings.maxHold {
                endHold(.maxHold)
            } else {
                tryUpstream()
            }
        }

        private func endHold(_ reason: HoldEnd) {
            reportHoldEnd(reason, status: nil)
            fail()
        }

        private func reportHoldEnd(_ reason: HoldEnd, status: Int?) {
            proxy?.emit(.holdEnded(
                resource: target.resource,
                session: target.session,
                held: heldFor,
                attempts: attempts,
                end: reason,
                status: status
            ))
        }

        // MARK: The end

        private func answer(_ response: UpstreamResponse) {
            if (200..<300).contains(response.status) {
                proxy?.markEstablished(session: target.session)
            }
            finish()
            client.respond(
                status: response.status,
                headers: response.headers,
                body: response.body
            )
        }

        /// Closes the request without a response.
        private func fail() {
            finish()
            client.abort()
        }

        private func finish() {
            isFinished = true
            retryTimer?.cancel()
            retryTimer = nil
            proxy?.exchangeFinished(self)
        }

        // MARK: The upstream request

        /// The request that goes upstream: the player's, with the headers
        /// `HlsHoldProxy.forwardedRequestHeaders` lets through.
        private static func upstreamRequest(
            for target: Target,
            method: String,
            headers: [HeaderField],
            timings: Timings
        ) -> URLRequest {
            var request = URLRequest(
                url: target.upstream,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: UpstreamAttempt.backstopTimeout(timings)
            )
            request.httpMethod = method
            for header in headers
            where HlsHoldProxy.forwardedRequestHeaders.contains(header.name) {
                request.addValue(header.value, forHTTPHeaderField: header.name)
            }
            // A range, or the length a HEAD reports, is about the bytes as
            // stored: no compression then. Otherwise URLSession asks for a
            // compressed body itself (playlists shrink to a quarter) and
            // decompresses it: the loopback leg costs nothing.
            let isRange = request.value(forHTTPHeaderField: "Range") != nil
            if method == "HEAD" || isRange {
                request.setValue(
                    "identity", forHTTPHeaderField: "Accept-Encoding"
                )
            }
            return request
        }
    }
}
