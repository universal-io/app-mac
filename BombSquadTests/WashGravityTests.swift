import AppKit
import XCTest
@testable import Universal_IO

/// The lattice's pull toward the cursor is geometry, so it is pinned here:
/// toward the centre, stronger close in, nothing beyond the reach, and never
/// past the centre. The sheet is also drawn once at display size to keep the
/// per-dot drawing inside a frame.
final class WashGravityTests: XCTestCase {
    private let centre = CGPoint(x: 800, y: 500)

    func testBeyondReachIsUntouched() {
        let far = CGPoint(x: centre.x + WashStyle.gravityReach + 1, y: centre.y)
        XCTAssertEqual(WashStyle.gravity(displacing: far, toward: centre), far)
        let edge = CGPoint(x: centre.x + WashStyle.gravityReach, y: centre.y)
        XCTAssertEqual(WashStyle.gravity(displacing: edge, toward: centre), edge)
    }

    func testCentreStaysPut() {
        XCTAssertEqual(WashStyle.gravity(displacing: centre, toward: centre), centre)
    }

    func testPullIsTowardCentreAndNeverPastIt() {
        for distance in stride(from: 1.0, to: Double(WashStyle.gravityReach), by: 7) {
            // Off-axis, at exactly `distance` from the centre.
            let point = CGPoint(x: centre.x + distance * 0.6, y: centre.y + distance * 0.8)
            let moved = WashStyle.gravity(displacing: point, toward: centre)
            let before = hypot(point.x - centre.x, point.y - centre.y)
            let after = hypot(moved.x - centre.x, moved.y - centre.y)
            XCTAssertLessThan(after, before, "distance \(distance)")
            XCTAssertGreaterThan(after, 0, "distance \(distance)")
            // Same direction: the cross product of the two offsets is zero.
            let cross = (point.x - centre.x) * (moved.y - centre.y)
                - (point.y - centre.y) * (moved.x - centre.x)
            XCTAssertEqual(cross, 0, accuracy: 1e-6)
        }
    }

    func testPullFractionFallsOffWithDistance() {
        func fraction(_ distance: CGFloat) -> CGFloat {
            let point = CGPoint(x: centre.x + distance, y: centre.y)
            let moved = WashStyle.gravity(displacing: point, toward: centre)
            return 1 - (moved.x - centre.x) / distance
        }
        let reach = WashStyle.gravityReach
        XCTAssertEqual(fraction(0.001), WashStyle.gravityPull, accuracy: 1e-4)
        XCTAssertGreaterThan(fraction(reach * 0.1), fraction(reach * 0.4))
        XCTAssertGreaterThan(fraction(reach * 0.4), fraction(reach * 0.8))
        XCTAssertGreaterThan(fraction(reach * 0.8), 0)
        XCTAssertEqual(fraction(reach), 0)
    }

    func testMarginCoversTheFurthestAnyDotTravels() {
        // The drawing extends its grid by the largest displacement so pulled-in
        // dots arrive rather than a bare edge appearing. The maximum of
        // r·pull·(1 − r/R)² is at r = R/3.
        var largest: CGFloat = 0
        for distance in stride(from: 1.0, to: Double(WashStyle.gravityReach), by: 1) {
            let point = CGPoint(x: centre.x + distance, y: centre.y)
            let moved = WashStyle.gravity(displacing: point, toward: centre)
            largest = max(largest, point.x - moved.x)
        }
        let claimed = WashStyle.gravityReach / 3 * WashStyle.gravityPull * 4 / 9
        XCTAssertEqual(largest, claimed, accuracy: 0.5)
    }

    func testSheetDrawsAtDisplaySizeWithinAFrame() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(bounds.width), height: Int(bounds.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Warm once so the measurement is the drawing, not the first-use setup.
        WashStyle.drawSheet(in: bounds, gravity: centre, context: context)
        let began = Date()
        WashStyle.drawSheet(in: bounds, gravity: centre, context: context)
        let elapsed = Date().timeIntervalSince(began)
        XCTAssertLessThan(elapsed, 0.016, "one sheet took \\(elapsed * 1000) ms")
    }
}
