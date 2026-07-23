import XCTest
@testable import Universal_IO

final class GatewayRoutingTests: XCTestCase {
    func testBundledProductionGatewayIsTheOnlyResolvedRoute() {
        XCTAssertEqual(
            BombSquadConfig.resolvedAPIBaseURL(),
            "https://api.universal-io.com"
        )
    }

    func testEnvironmentCannotOverrideProductionGateway() {
        let snapshot = BombSquadConfig.snapshot(environment: [
            BombSquadConfig.apiBaseURLKey: "http://127.0.0.1:3001"
        ])

        XCTAssertEqual(snapshot.apiBaseURL.value, "https://api.universal-io.com")
    }

    func testHTML404IsNotExposedAsRawPageSource() {
        let data = Data("<!DOCTYPE html><html><head></head><body>not found</body></html>".utf8)
        let error = GatewayAPI.error(status: 404, data: data)

        XCTAssertEqual(
            (error as? LocalizedError)?.errorDescription,
            "必要なGateway APIが本番環境に配備されていません（HTTP 404）。"
        )
    }
}
