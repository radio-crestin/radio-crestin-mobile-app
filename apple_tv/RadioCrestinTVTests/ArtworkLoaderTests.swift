import UIKit
import XCTest
@testable import RadioCrestinTV

/// Station and song pictures: one download per URL, kept in memory, the
/// fallbacks tried in order, and refusals told apart from passing faults.
@MainActor
final class ArtworkLoaderTests: XCTestCase {

    override func tearDown() {
        StubArtworkProtocol.reset()
        super.tearDown()
    }

    /// A loader that downloads through `StubArtworkProtocol`.
    private func makeLoader() -> ArtworkLoader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubArtworkProtocol.self]
        return ArtworkLoader(session: URLSession(configuration: configuration))
    }

    /// A URL of its own for each picture, so tests never share answers.
    private func url(_ name: String) -> URL {
        URL(string: "https://img.test/\(UUID().uuidString)/\(name).png")!
    }

    // MARK: - One download, then memory

    func test_a_picture_is_downloaded_once_however_many_views_ask() async {
        let loader = makeLoader()
        let logo = url("logo")
        StubArtworkProtocol.serve(.picture, at: logo)

        let images = await withTaskGroup(of: UIImage?.self) { group in
            for _ in 0..<5 {
                group.addTask { await loader.image(for: logo) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let again = await loader.image(for: logo)

        XCTAssertEqual(StubArtworkProtocol.requests(for: logo), 1)
        XCTAssertEqual(images.compactMap { $0 }.count, 5)
        XCTAssertTrue(images.allSatisfy { $0 === again })
    }

    func test_a_loaded_picture_is_ready_in_memory_for_the_next_view() async {
        let loader = makeLoader()
        let logo = url("logo")
        StubArtworkProtocol.serve(.picture, at: logo)
        XCTAssertNil(loader.cachedImage(for: [logo]))

        let loaded = await loader.image(for: [logo])

        XCTAssertNotNil(loaded)
        XCTAssertTrue(loader.cachedImage(for: [logo]) === loaded)
    }

    func test_memory_can_be_emptied() async {
        let loader = makeLoader()
        let logo = url("logo")
        StubArtworkProtocol.serve(.picture, at: logo)
        _ = await loader.image(for: logo)

        loader.removeAllImages()

        XCTAssertNil(loader.cachedImage(for: [logo]))
    }

    func test_the_app_lets_its_pictures_go_on_a_memory_warning() async throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).png")
        try StubArtworkProtocol.picture.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let loader = ArtworkLoader.shared
        let loaded = await loader.image(for: file)
        XCTAssertNotNil(loaded)
        XCTAssertNotNil(loader.cachedImage(for: [file]))

        NotificationCenter.default.post(
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        let emptied = await eventually { loader.cachedImage(for: [file]) == nil }
        XCTAssertTrue(emptied)
    }

    // MARK: - Fallbacks

    func test_the_logo_shows_when_the_song_cover_is_refused() async {
        let loader = makeLoader()
        let cover = url("cover")
        let logo = url("logo")
        StubArtworkProtocol.serve(.status(404), at: cover)
        StubArtworkProtocol.serve(.picture, at: logo)

        let image = await loader.image(for: [cover, logo])

        XCTAssertNotNil(image)
        XCTAssertEqual(StubArtworkProtocol.order, [cover, logo])
        XCTAssertTrue(loader.cachedImage(for: [cover, logo]) === image)
    }

    func test_the_song_cover_wins_over_the_logo() async {
        let loader = makeLoader()
        let cover = url("cover")
        let logo = url("logo")
        StubArtworkProtocol.serve(.picture, at: cover)
        StubArtworkProtocol.serve(.picture, at: logo)
        let logoImage = await loader.image(for: logo)

        let image = await loader.image(for: [cover, logo])

        XCTAssertNotNil(image)
        XCTAssertFalse(image === logoImage)
    }

    /// The logo in memory must not show for a moment before the cover
    /// that is meant to cover it.
    func test_a_logo_in_memory_waits_for_a_cover_not_yet_tried() async {
        let loader = makeLoader()
        let cover = url("cover")
        let logo = url("logo")
        StubArtworkProtocol.serve(.picture, at: logo)
        _ = await loader.image(for: logo)

        XCTAssertNil(loader.cachedImage(for: [cover, logo]))
    }

    /// The system's Now Playing would rather show the logo than nothing
    /// while the cover loads.
    func test_any_picture_in_memory_can_show_while_the_cover_loads() async {
        let loader = makeLoader()
        let cover = url("cover")
        let logo = url("logo")
        StubArtworkProtocol.serve(.picture, at: logo)
        let logoImage = await loader.image(for: logo)

        XCTAssertNotNil(logoImage)
        XCTAssertTrue(loader.anyCachedImage(for: [cover, logo]) === logoImage)
    }

    func test_the_cover_in_memory_comes_before_the_logo() async {
        let loader = makeLoader()
        let cover = url("cover")
        let logo = url("logo")
        StubArtworkProtocol.serve(.picture, at: cover)
        StubArtworkProtocol.serve(.picture, at: logo)
        let coverImage = await loader.image(for: cover)
        _ = await loader.image(for: logo)

        XCTAssertTrue(loader.anyCachedImage(for: [cover, logo]) === coverImage)
        XCTAssertNil(loader.anyCachedImage(for: [url("other")]))
    }

    func test_nothing_shows_when_every_url_fails() async {
        let loader = makeLoader()
        let cover = url("cover")
        let logo = url("logo")
        StubArtworkProtocol.serve(.status(404), at: cover)
        StubArtworkProtocol.serve(.status(410), at: logo)

        let image = await loader.image(for: [cover, logo])

        XCTAssertNil(image)
        XCTAssertNil(loader.cachedImage(for: [cover, logo]))
    }

    // MARK: - Refusals and faults

    func test_a_refused_picture_is_not_asked_for_again() async {
        let loader = makeLoader()
        let cover = url("cover")
        StubArtworkProtocol.serve(.status(404), at: cover)

        _ = await loader.image(for: cover)
        _ = await loader.image(for: cover)

        XCTAssertEqual(StubArtworkProtocol.requests(for: cover), 1)
    }

    func test_bytes_that_are_no_picture_count_as_a_refusal() async {
        let loader = makeLoader()
        let cover = url("cover")
        StubArtworkProtocol.serve(.bytes(Data("<html></html>".utf8)), at: cover)

        let first = await loader.image(for: cover)
        _ = await loader.image(for: cover)

        XCTAssertNil(first)
        XCTAssertEqual(StubArtworkProtocol.requests(for: cover), 1)
    }

    /// A passing fault must not leave a station without its logo for the
    /// rest of the session.
    func test_a_server_fault_is_asked_for_again() async {
        let loader = makeLoader()
        let logo = url("logo")
        StubArtworkProtocol.serve(.status(503), at: logo)

        let first = await loader.image(for: logo)
        StubArtworkProtocol.serve(.picture, at: logo)
        let second = await loader.image(for: logo)

        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(StubArtworkProtocol.requests(for: logo), 2)
    }

    func test_a_network_error_is_asked_for_again() async {
        let loader = makeLoader()
        let logo = url("logo")
        StubArtworkProtocol.serve(.offline, at: logo)

        let first = await loader.image(for: logo)
        StubArtworkProtocol.serve(.picture, at: logo)
        let second = await loader.image(for: logo)

        XCTAssertNil(first)
        XCTAssertNotNil(second)
    }
}

/// Answers `ArtworkLoader`'s requests from a table, and counts them.
private final class StubArtworkProtocol: URLProtocol {
    enum Answer {
        case picture
        case status(Int)
        case bytes(Data)
        case offline
    }

    private static let lock = NSLock()
    private static var answers: [URL: Answer] = [:]
    private static var asked: [URL] = []

    static func serve(_ answer: Answer, at url: URL) {
        lock.withLock { answers[url] = answer }
    }

    static func requests(for url: URL) -> Int {
        lock.withLock { asked.filter { $0 == url }.count }
    }

    /// Every request so far, in the order they came.
    static var order: [URL] {
        lock.withLock { asked }
    }

    static func reset() {
        lock.withLock {
            answers = [:]
            asked = []
        }
    }

    /// A small opaque PNG.
    static let picture: Data = UIGraphicsImageRenderer(
        size: CGSize(width: 8, height: 8)
    ).pngData { context in
        UIColor.systemPink.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
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
        let answer = Self.lock.withLock {
            Self.asked.append(url)
            return Self.answers[url] ?? .status(404)
        }
        let status: Int
        let body: Data
        switch answer {
        case .offline:
            client?.urlProtocol(
                self, didFailWithError: URLError(.notConnectedToInternet)
            )
            return
        case .picture:
            (status, body) = (200, Self.picture)
        case .status(let code):
            (status, body) = (code, Data())
        case .bytes(let data):
            (status, body) = (200, data)
        }
        if let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: nil
        ) {
            client?.urlProtocol(
                self, didReceive: response, cacheStoragePolicy: .notAllowed
            )
        }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
