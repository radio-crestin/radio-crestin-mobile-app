import Foundation

/// Minimal GraphQL client for the tvOS app — URLSession + Codable, no
/// runtime dep on Apollo. The Hasura endpoint accepts the standard
/// `{"query": "...", "variables": {...}}` shape, so a single typed
/// helper covers every query the app needs.
enum GraphQLError: Error, LocalizedError {
    case invalidURL
    case http(Int)
    case empty
    case server(messages: [String])
    case decoding(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "GraphQL endpoint URL is malformed"
        case .http(let code): return "HTTP \(code) from GraphQL server"
        case .empty: return "Empty response from GraphQL server"
        case .server(let messages):
            return "GraphQL: " + messages.joined(separator: "; ")
        case .decoding(let err): return "Decoding failed: \(err)"
        }
    }
}

struct GraphQLClient {
    let endpoint: URL
    let authToken: String
    let session: URLSession

    init(
        endpoint: URL = URL(string: "https://api.radiocrestin.ro/v1/graphql")!,
        // Public read-only token; the same one the iOS / Android apps ship.
        // Treat as non-secret.
        authToken: String = "Token public",
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.authToken = authToken
        self.session = session
    }

    /// Runs a GraphQL query and decodes `data` into `T`.
    /// Throws `GraphQLError.server` when the response carries an `errors`
    /// array (so callers don't silently get an empty struct).
    func query<T: Decodable>(
        _ query: String,
        variables: [String: Any]? = nil,
        as: T.Type
    ) async throws -> T {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(authToken, forHTTPHeaderField: "Authorization")

        var body: [String: Any] = ["query": query]
        if let variables { body["variables"] = variables }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GraphQLError.empty
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GraphQLError.http(http.statusCode)
        }
        guard !data.isEmpty else { throw GraphQLError.empty }

        // Two-step decode: pull errors[] first, fall through to data.
        let envelope = try JSONDecoder().decode(
            GraphQLEnvelope<T>.self, from: data
        )
        if let errors = envelope.errors, !errors.isEmpty {
            throw GraphQLError.server(messages: errors.map { $0.message })
        }
        guard let payload = envelope.data else { throw GraphQLError.empty }
        return payload
    }
}

private struct GraphQLEnvelope<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLErrorMessage]?
}

private struct GraphQLErrorMessage: Decodable {
    let message: String
}
