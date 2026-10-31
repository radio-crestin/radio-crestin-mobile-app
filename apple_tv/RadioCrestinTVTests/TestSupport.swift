import Foundation
@testable import RadioCrestinTV

/// A TCP port on the loopback that accepts connections and never answers.
///
/// AVPlayer connects, sends its request and waits, so an item pointed here
/// stays "connecting" for the length of a test: no failure of its own (a
/// refused port fails the item within milliseconds) races the events a
/// test sends. The port closes when the server is released.
final class SilentServer {
    let port: UInt16
    private let descriptor: Int32

    /// Connections the kernel completes before anyone accepts them. Nothing
    /// ever accepts; AVPlayer opens one or two per item, so a test never
    /// comes close.
    private static let backlog: Int32 = 16

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // any free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let isListening = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0
                    && listen(fd, Self.backlog) == 0
                    && getsockname(fd, $0, &length) == 0
            }
        }
        guard isListening else {
            close(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        descriptor = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit {
        close(descriptor)
    }

    /// A stream of `type` that this server (never) serves at `path`.
    func stream(
        _ type: String,
        at path: String,
        order: Int = 0
    ) -> StationStream {
        StationStream(
            order: order,
            type: type,
            streamUrl: "http://127.0.0.1:\(port)\(path)"
        )
    }
}

/// Waits up to `timeout` seconds for `condition`, letting the main actor run
/// what is queued meanwhile (observer deliveries, the engine's timers).
/// Returns whether it came true. Looks every 10 ms: far finer than anything
/// the tests wait for, and cheap.
@MainActor
func eventually(
    timeout: TimeInterval = 2,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Lets the main actor run what is already queued, for tests that check
/// that something does *not* happen. A tenth of a second is many times
/// what a queued main-actor delivery takes.
@MainActor
func letQueuedWorkRun() async {
    try? await Task.sleep(for: .milliseconds(100))
}
