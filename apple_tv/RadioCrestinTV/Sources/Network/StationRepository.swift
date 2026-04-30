import Foundation

/// One-stop shop for fetching the station list. The Flutter app polls
/// every 5–10s; on tvOS we refresh on app foreground + on user-initiated
/// reload. Polling can be added later if metadata-staleness becomes a
/// real problem on the home screen.
final class StationRepository {
    private let client: GraphQLClient

    init(client: GraphQLClient = GraphQLClient()) {
        self.client = client
    }

    private static let getStationsQuery = """
    query GetStations {
      stations(order_by: {order: asc, title: asc}) {
        id
        slug
        order
        title
        thumbnail_url
        total_listeners
        station_streams { order type stream_url }
        uptime { is_up timestamp }
        now_playing {
          id
          timestamp
          song {
            id
            name
            thumbnail_url
            artist { id name thumbnail_url }
          }
        }
        reviews { id stars message }
      }
    }
    """

    func fetchStations() async throws -> [Station] {
        let response = try await client.query(
            Self.getStationsQuery,
            as: GetStationsResponse.self
        )
        return response.stations
    }
}

private struct GetStationsResponse: Decodable {
    let stations: [Station]
}
