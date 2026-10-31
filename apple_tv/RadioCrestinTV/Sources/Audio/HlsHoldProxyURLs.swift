import Foundation

/// How upstream URLs map to the proxy's and back, and how a playlist's URIs
/// are sent back through it. Pure functions, unit-tested on their own.
extension HlsHoldProxy {
    /// The upstream URL a proxy request stands for, and its session.
    struct Target {
        let session: Int
        let upstream: URL

        /// The last path segment, for the log: `index-5m.m3u8`, a segment.
        var resource: String {
            let last = upstream.lastPathComponent
            return last.isEmpty ? "/" : last
        }
    }

    /// Whether `url` is one the proxy fetches: http(s), of an allowed host,
    /// without user info. `allowedHosts` are lowercase.
    static func allows(_ url: URL, allowedHosts: Set<String>) -> Bool {
        guard let components = URLComponents(
                  url: url, resolvingAgainstBaseURL: true
              ),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil, components.password == nil,
              let host = components.host?.lowercased()
        else { return false }
        return allowedHosts.contains(host)
    }

    /// `/<session>/<scheme>/<host[:port]><path>?<query>` for `url`:
    /// root-relative, so that it resolves against whichever proxy URL the
    /// player used. The path and query stay percent-encoded as they were;
    /// the query is kept because listeners are counted from it. Nil for a
    /// URL without a scheme or a host.
    static func proxyPath(for url: URL, session: Int) -> String? {
        guard let components = URLComponents(
                  url: url, resolvingAgainstBaseURL: true
              ),
              let scheme = components.scheme?.lowercased(),
              let authority = authority(of: components)
        else { return nil }
        let path = components.percentEncodedPath.isEmpty
            ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return "/\(session)/\(scheme)/\(authority)\(path)\(query)"
    }

    /// The upstream target of a request to the proxy: its request target
    /// (`/<session>/<scheme>/<authority>/<path…>?<query>`) taken apart.
    /// Nil for anything else, or a host that is not allowed.
    static func target(
        ofRequestTarget requestTarget: String,
        allowedHosts: Set<String>
    ) -> Target? {
        let pathAndQuery = requestTarget.split(
            separator: "?", maxSplits: 1, omittingEmptySubsequences: false
        )
        let query = pathAndQuery.count > 1 ? "?\(pathAndQuery[1])" : ""
        let parts = pathAndQuery[0].split(
            separator: "/", omittingEmptySubsequences: false
        )
        guard parts.count >= 5, parts[0].isEmpty,
              let session = Int(parts[1])
        else { return nil }
        let scheme = parts[2]
        guard scheme == "http" || scheme == "https" else { return nil }
        let path = parts[4...].joined(separator: "/")
        guard let upstream = URL(
                  string: "\(scheme)://\(parts[3])/\(path)\(query)"
              ),
              allows(upstream, allowedHosts: allowedHosts)
        else { return nil }
        return Target(session: session, upstream: upstream)
    }

    /// The proxy path for a URI in `target`'s response that would not
    /// resolve through the proxy by itself: absolute on an allowed host, or
    /// root-relative. A scheme-relative URI of another host gets its
    /// scheme, which resolving it against the proxy's `http` would get
    /// wrong. Nil: keep it (relative, or another host).
    static func proxiedURI(
        _ uri: String,
        of target: Target,
        allowedHosts: Set<String>
    ) -> String? {
        guard let base = URLComponents(
                  url: target.upstream, resolvingAgainstBaseURL: true
              ),
              let scheme = base.scheme?.lowercased()
        else { return nil }
        if uri.hasPrefix("//") {
            guard let absolute = URL(string: "\(scheme):\(uri)") else {
                return nil
            }
            return allows(absolute, allowedHosts: allowedHosts)
                ? proxyPath(for: absolute, session: target.session)
                : absolute.absoluteString
        }
        if uri.hasPrefix("/") {
            guard let authority = authority(of: base) else { return nil }
            return "/\(target.session)/\(scheme)/\(authority)\(uri)"
        }
        guard let parsed = URL(string: uri), parsed.scheme != nil,
              allows(parsed, allowedHosts: allowedHosts)
        else { return nil }
        return proxyPath(for: parsed, session: target.session)
    }

    /// `body`, a playlist of `target`, with the URIs that would not come
    /// back through the proxy rewritten (see `proxiedURI`); `body` itself
    /// when there are none, which is the case of our origin's playlists:
    /// their segment URIs are relative.
    static func rewritePlaylist(
        _ body: Data,
        of target: Target,
        allowedHosts: Set<String>
    ) -> Data {
        // Latin-1 maps every byte to one character and back, so the bytes
        // not rewritten (UTF-8 song titles included) stay exactly as they
        // were.
        guard let text = String(data: body, encoding: .isoLatin1) else {
            return body
        }
        // `.literal` compares UTF-16 code units, so "\n/" is found after a
        // "\r" too, which Swift's Character comparison would not do.
        let mayNeedRewriting = ["://", "\n/", "URI=\"/"].contains {
            text.range(of: $0, options: .literal) != nil
        }
        guard mayNeedRewriting else { return body }
        let rewritten = rewritePlaylistURIs(text) {
            proxiedURI($0, of: target, allowedHosts: allowedHosts)
        }
        guard rewritten != text,
              let data = rewritten.data(using: .isoLatin1)
        else { return body }
        return data
    }

    /// Rewrites the URIs of an HLS `playlist` with `map`: the URI lines and
    /// the `URI="…"` attributes of the tags. `map` returns nil to keep one.
    /// Everything else, line endings included, stays as it is.
    static func rewritePlaylistURIs(
        _ playlist: String,
        map: (String) -> String?
    ) -> String {
        // Foundation's split works on UTF-16 code units: Swift's own sees
        // "\r\n" as one Character and would not split a CRLF line at "\n".
        var lines = playlist.components(separatedBy: "\n")
        for index in lines.indices {
            let line = lines[index]
            let endsWithCR = line.hasSuffix("\r")
            let content = endsWithCR ? String(line.dropLast()) : line
            let rewritten: String?
            if content.hasPrefix("#") {
                rewritten = content.range(of: uriAttributeOpening) == nil
                    ? nil
                    : rewriteURIAttributes(in: content, map: map)
            } else {
                rewritten = rewriteURILine(content, map: map)
            }
            if let rewritten, rewritten != content {
                lines[index] = endsWithCR ? rewritten + "\r" : rewritten
            }
        }
        return lines.joined(separator: "\n")
    }

    private static let uriAttributeOpening = "URI=\""

    /// A URI line with its URI mapped, its surrounding blanks kept; nil to
    /// keep it.
    private static func rewriteURILine(
        _ line: String,
        map: (String) -> String?
    ) -> String? {
        let uri = line.trimmingCharacters(in: .whitespaces)
        guard !uri.isEmpty, let mapped = map(uri),
              let range = line.range(of: uri, options: .literal)
        else { return nil }
        return line.replacingCharacters(in: range, with: mapped)
    }

    /// A tag line with the value of each `URI="…"` mapped (as the iPhone
    /// app's `URI="([^"]*)"` pattern does: an attribute whose name ends in
    /// `URI`, such as an interstitial's `X-ASSET-URI`, counts too).
    private static func rewriteURIAttributes(
        in line: String,
        map: (String) -> String?
    ) -> String {
        var result = ""
        var rest = line[...]
        while let opening = rest.range(
                  of: uriAttributeOpening, options: .literal
              ),
              let closing = rest[opening.upperBound...].firstIndex(of: "\"") {
            let value = String(rest[opening.upperBound..<closing])
            result += rest[..<opening.upperBound]
            result += map(value) ?? value
            result += "\""
            rest = rest[rest.index(after: closing)...]
        }
        result += rest
        return result
    }

    /// `host[:port]` of `components`, the host lowercased and a default
    /// port left out, as the iPhone app's URLs have them.
    private static func authority(of components: URLComponents) -> String? {
        guard let host = components.percentEncodedHost?.lowercased(),
              !host.isEmpty
        else { return nil }
        guard let port = components.port,
              port != defaultPort(ofScheme: components.scheme)
        else { return host }
        return "\(host):\(port)"
    }

    private static func defaultPort(ofScheme scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
