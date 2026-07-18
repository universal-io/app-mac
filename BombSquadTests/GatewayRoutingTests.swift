import XCTest
@testable import Universal_IO

final class GatewayRoutingTests: XCTestCase {
    func testStaleLocalValueIsInertByDefault() throws {
        let plan = try XCTUnwrap(BombSquadConfig.makeGatewayRoutePlan(
            developmentValue: "http://127.0.0.1:3001",
            productionValue: "https://api.universal-io.com",
            developmentModeRequested: false,
            allowsDevelopmentOverride: true
        ))

        XCTAssertEqual(plan.preferredURL.absoluteString, "https://api.universal-io.com")
        XCTAssertFalse(plan.usesDevelopmentOverride)
    }

    func testExplicitDebugLocalModeUsesDevelopmentGatewayOnly() throws {
        let plan = try XCTUnwrap(BombSquadConfig.makeGatewayRoutePlan(
            developmentValue: "http://127.0.0.1:3001",
            productionValue: "https://api.universal-io.com",
            developmentModeRequested: true,
            allowsDevelopmentOverride: true
        ))

        XCTAssertEqual(plan.preferredURL.absoluteString, "http://127.0.0.1:3001")
        XCTAssertTrue(plan.usesDevelopmentOverride)
    }

    func testExplicitLocalModeWithoutValidURLFailsClosed() {
        let plan = BombSquadConfig.makeGatewayRoutePlan(
            developmentValue: nil,
            productionValue: "https://api.universal-io.com",
            developmentModeRequested: true,
            allowsDevelopmentOverride: true
        )

        XCTAssertNil(plan)
    }

    func testReleaseIgnoresExplicitLocalMode() throws {
        let plan = try XCTUnwrap(BombSquadConfig.makeGatewayRoutePlan(
            developmentValue: "http://127.0.0.1:3001",
            productionValue: "https://api.universal-io.com",
            developmentModeRequested: true,
            allowsDevelopmentOverride: false
        ))

        XCTAssertEqual(plan.preferredURL.absoluteString, "https://api.universal-io.com")
        XCTAssertFalse(plan.usesDevelopmentOverride)
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
