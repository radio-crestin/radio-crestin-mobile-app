import XCTest
@testable import RadioCrestinTV

/// The properties of an `exception_caught` event: the description in the
/// device's language, plus a domain and a code that are the same in every
/// language.
final class AnalyticsErrorTests: XCTestCase {

    private enum SampleError: Error {
        case first
        case second
    }

    /// The type of a URL error reads "NSError" here: its domain and code
    /// are what tell a timeout from a lost connection.
    func test_a_url_error_sends_its_domain_and_code() {
        let props = Analytics.errorProperties(
            URLError(.timedOut), context: "full_refresh"
        )

        XCTAssertEqual(props["error_domain"] as? String, NSURLErrorDomain)
        XCTAssertEqual(props["error_code"] as? Int, NSURLErrorTimedOut)
        XCTAssertEqual(props["context"] as? String, "full_refresh")
        XCTAssertEqual(
            props["error_description"] as? String,
            URLError(.timedOut).localizedDescription
        )
    }

    func test_an_nserror_sends_its_own_domain_and_code() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800)

        let props = Analytics.errorProperties(error, context: "playback")

        XCTAssertEqual(props["error_domain"] as? String, "AVFoundationErrorDomain")
        XCTAssertEqual(props["error_code"] as? Int, -11800)
    }

    /// A Swift error bridges to a domain naming its type and a code per
    /// case, so its cases group apart.
    func test_a_swift_error_sends_its_type_and_case() {
        let first = Analytics.errorProperties(SampleError.first, context: "x")
        let second = Analytics.errorProperties(SampleError.second, context: "x")

        let domain = first["error_domain"] as? String
        XCTAssertTrue(domain?.hasSuffix("SampleError") ?? false, "\(domain ?? "nil")")
        XCTAssertEqual(second["error_domain"] as? String, domain)
        XCTAssertNotEqual(first["error_code"] as? Int, second["error_code"] as? Int)
    }

    /// Extra properties come along, but never replace the error's own.
    func test_extra_properties_are_added_without_replacing_the_errors() {
        let props = Analytics.errorProperties(
            URLError(.notConnectedToInternet),
            context: "stream",
            extra: ["station_slug": "radio-eldad", "error_code": 7]
        )

        XCTAssertEqual(props["station_slug"] as? String, "radio-eldad")
        XCTAssertEqual(
            props["error_code"] as? Int, NSURLErrorNotConnectedToInternet
        )
    }
}
