import XCTest
@testable import Universal_IO

/// The one rule of the component that tells a user they cannot make a request
/// before they make one: which refusals are worth standing on screen.
final class GatewayAvailabilityTests: XCTestCase {
    private func refusal(_ code: String?) -> String? {
        GatewayAvailability.standingRefusal(
            in: ProviderError.gateway(message: "説明の文", code: code)
        )
    }

    /// A spent month refuses the next request too, which is exactly why it is
    /// worth saying up front. This is the case the feature exists for.
    func testAccountLevelRefusalsStand() {
        XCTAssertEqual(refusal("QUOTA_EXCEEDED"), "説明の文")
        XCTAssertEqual(refusal("SERVICE_CAPACITY_REACHED"), "説明の文")
        XCTAssertEqual(refusal("PAYMENT_REQUIRED"), "説明の文")
        XCTAssertEqual(refusal("UNAUTHENTICATED"), "説明の文")
    }

    /// A provider outage, a rate limit and a dropped connection all resolve by
    /// themselves. A banner for those outlives the condition it describes, and
    /// a banner that is wrong once stops being read.
    func testTransientFailuresDoNotStand() {
        XCTAssertNil(refusal("PROVIDER_ERROR"))
        XCTAssertNil(refusal("RATE_LIMITED"))
        XCTAssertNil(refusal("INTERNAL_ERROR"))
        XCTAssertNil(refusal(nil))
        XCTAssertNil(GatewayAvailability.standingRefusal(
            in: ProviderError.transport(
                code: URLError.Code.notConnectedToInternet.rawValue,
                description: "offline"
            )
        ))
        XCTAssertNil(GatewayAvailability.standingRefusal(
            in: ProviderError.http(status: 502, body: "upstream said no")
        ))
    }

    /// The sentence shown is the gateway contract's own, resolved once in
    /// `GatewayAPI.error`, so the banner and the failure message cannot drift
    /// into describing the same refusal two different ways.
    func testTheSentenceIsTheOneResolvedFromTheContract() throws {
        let body = Data(#"{"error":{"code":"QUOTA_EXCEEDED","message":"ignored"}}"#.utf8)
        let error = GatewayAPI.error(status: 429, data: body)
        let standing = try XCTUnwrap(GatewayAvailability.standingRefusal(in: error))
        XCTAssertEqual(standing, UserFacingError.serverExplanation(for: error))
        XCTAssertTrue(standing.contains("今月の利用枠を使い切りました"))
    }
}
