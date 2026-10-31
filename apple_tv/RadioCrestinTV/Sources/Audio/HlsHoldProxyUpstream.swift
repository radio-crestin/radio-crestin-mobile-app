import Foundation

/// The upstream leg of the proxy: one try of a request at the origin.
extension HlsHoldProxy {
    /// The origin's response, read whole, as the client gets it.
    struct UpstreamResponse {
        let status: Int
        /// The relayed headers, Content-Length included when due.
        let headers: [HeaderField]
        let body: Data
    }

    /// One upstream request of an `Exchange`, through URLSession.
    ///
    /// The body is read whole before the client gets the response, so that
    /// one that fails part way is retried unseen. HLS bodies are small
    /// (playlists ~13 KB, segments ~50 KB), so the iPhone app's streaming
    /// of bodies over 4 MB is left out; a body over `maxBodyBytes` fails.
    ///
    /// Timeouts. URLSession has a single timeout for a request, an idle one
    /// that restarts with every byte received, and no event when the
    /// connection opens. The iPhone app's three are approximated by the
    /// attempt's own timer on the proxy's queue: the response headers must
    /// arrive within `connectTimeout + responseTimeout` of the start (DNS,
    /// TCP, TLS, then the origin's answer: 15 s by default), and the body
    /// may then pause for at most `bodyIdleTimeout` between two chunks.
    /// URLSession's own idle timeout is set above both (`backstopTimeout`),
    /// so it never fires first.
    ///
    /// Lives on the proxy's queue: URLSession calls its delegate methods
    /// there (see `HlsHoldProxy.upstreamSession()`).
    final class UpstreamAttempt: NSObject, URLSessionDataDelegate {
        enum Outcome {
            case response(UpstreamResponse)
            /// No whole response arrived; nothing reached the client.
            /// `generation`: the upstream session the try used.
            case failure(Error, generation: Int)
        }

        /// The upstream session this try runs on (see
        /// `HlsHoldProxy.renewConnections(afterFailureOn:)`).
        let generation: Int

        private let task: URLSessionDataTask
        private let target: Target
        private let method: String
        private let timings: Timings
        private let allowedHosts: Set<String>
        private let queue: DispatchQueue
        private var onHeaders: (() -> Void)?
        private var completion: ((Outcome) -> Void)?
        private var response: HTTPURLResponse?
        private var body = Data()
        private var deadline: DispatchWorkItem?

        /// URLSession's own idle timeout: past the attempt's two, so that
        /// one of them always ends a try first, and reports it as such.
        static func backstopTimeout(_ timings: Timings) -> TimeInterval {
            timings.connectTimeout + timings.responseTimeout
                + timings.bodyIdleTimeout
        }

        /// `onHeaders`: the origin answered (with any status), called once
        /// the response headers arrive. `completion`: the outcome, called
        /// once, unless the attempt is abandoned first.
        init(
            request: URLRequest,
            target: Target,
            session: URLSession,
            generation: Int,
            timings: Timings,
            allowedHosts: Set<String>,
            queue: DispatchQueue,
            onHeaders: @escaping () -> Void,
            completion: @escaping (Outcome) -> Void
        ) {
            self.target = target
            self.method = request.httpMethod ?? "GET"
            self.generation = generation
            self.timings = timings
            self.allowedHosts = allowedHosts
            self.queue = queue
            self.onHeaders = onHeaders
            self.completion = completion
            task = session.dataTask(with: request)
            super.init()
            task.delegate = self
        }

        func start() {
            armDeadline(after: timings.connectTimeout + timings.responseTimeout)
            task.resume()
        }

        /// Ends the try at once and reports nothing: the exchange decides
        /// what follows.
        func abandon() {
            completion = nil
            onHeaders = nil
            disarmDeadline()
            task.cancel()
        }

        // MARK: URLSessionDataDelegate

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            // Relayed, not followed: the player follows the Location,
            // mapped back through the proxy (see `relayedHeaders`).
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler:
                @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard completion != nil,
                  let response = response as? HTTPURLResponse
            else {
                completionHandler(.cancel)
                return fail(ProxyError.notHTTP)
            }
            self.response = response
            onHeaders?()
            onHeaders = nil
            armDeadline(after: timings.bodyIdleTimeout)
            completionHandler(.allow)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive data: Data
        ) {
            guard completion != nil else { return }
            body.append(data)
            guard body.count <= HlsHoldProxy.maxBodyBytes else {
                task.cancel()
                return fail(
                    ProxyError.bodyTooLarge(limit: HlsHoldProxy.maxBodyBytes)
                )
            }
            armDeadline(after: timings.bodyIdleTimeout)
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            if let error { return fail(error) }
            guard let response else { return fail(ProxyError.notHTTP) }
            finish(.response(clientResponse(for: response)))
        }

        // MARK: Outcome

        private func fail(_ error: Error) {
            finish(.failure(error, generation: generation))
        }

        private func finish(_ outcome: Outcome) {
            guard let completion else { return }
            self.completion = nil
            onHeaders = nil
            disarmDeadline()
            completion(outcome)
        }

        private func armDeadline(after interval: TimeInterval) {
            deadline?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.timedOut() }
            deadline = item
            queue.asyncAfter(deadline: .now() + interval, execute: item)
        }

        private func disarmDeadline() {
            deadline?.cancel()
            deadline = nil
        }

        private func timedOut() {
            guard completion != nil else { return }
            task.cancel()
            fail(URLError(.timedOut))
        }

        // MARK: The client's response

        private func clientResponse(
            for response: HTTPURLResponse
        ) -> UpstreamResponse {
            let status = response.statusCode
            var bytes = body
            if (200..<300).contains(status), isPlaylist(response) {
                bytes = HlsHoldProxy.rewritePlaylist(
                    bytes, of: target, allowedHosts: allowedHosts
                )
            }
            var headers = relayedHeaders(of: response)
            if let length = contentLength(of: response, body: bytes) {
                headers.append(HeaderField(
                    name: "Content-Length", value: String(length)
                ))
            }
            return UpstreamResponse(
                status: status,
                headers: headers,
                body: method == "HEAD" ? Data() : bytes
            )
        }

        /// The response headers for the client, Content-Length aside.
        /// Content-Encoding is never relayed: URLSession has decompressed
        /// the body already.
        private func relayedHeaders(
            of response: HTTPURLResponse
        ) -> [HeaderField] {
            var headers: [HeaderField] = []
            for name in HlsHoldProxy.relayedResponseHeaders {
                // Repeated headers arrive joined with commas: the same for
                // every header relayed.
                if let value = response.value(forHTTPHeaderField: name) {
                    headers.append(HeaderField(name: name, value: value))
                }
            }
            if let location = response.value(forHTTPHeaderField: "Location") {
                let mapped = HlsHoldProxy.proxiedURI(
                    location, of: target, allowedHosts: allowedHosts
                )
                headers.append(HeaderField(
                    name: "Location", value: mapped ?? location
                ))
            }
            return headers
        }

        /// The length the client is told; nil for none: a status without a
        /// body, or a HEAD whose upstream length is of an encoded body.
        private func contentLength(
            of response: HTTPURLResponse,
            body: Data
        ) -> Int? {
            let status = response.statusCode
            if status < 200 || status == 204 || status == 304 { return nil }
            if method != "HEAD" { return body.count }
            let encoding = response.value(
                forHTTPHeaderField: "Content-Encoding"
            )?.lowercased()
            guard encoding == nil || encoding == "identity",
                  let length = response.value(
                      forHTTPHeaderField: "Content-Length"
                  )
            else { return nil }
            return Int(length)
        }

        private func isPlaylist(_ response: HTTPURLResponse) -> Bool {
            let type = response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased() ?? ""
            let path = target.upstream.path.lowercased()
            return type.contains("mpegurl")
                || path.hasSuffix(".m3u8")
                || path.hasSuffix(".m3u")
        }
    }
}
