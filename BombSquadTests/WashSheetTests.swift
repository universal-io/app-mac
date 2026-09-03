import AppKit
import XCTest
@testable import Universal_IO

/// The wash sheet is drawn dot by dot at display size on every cursor move, so
/// one drawing has to fit inside a frame. (The lattice's pull toward the cursor,
/// which this file used to pin as `WashGravityTests`, was removed on 2026-09-03.)
final class WashSheetTests: XCTestCase {
    func testSheetDrawsAtDisplaySizeWithinAFrame() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(bounds.width), height: Int(bounds.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Warm once so the measurement is the drawing, not the first-use setup.
        WashStyle.drawSheet(in: bounds, context: context)
        let began = Date()
        WashStyle.drawSheet(in: bounds, context: context)
        let elapsed = Date().timeIntervalSince(began)
        XCTAssertLessThan(elapsed, 0.016, "one sheet took \(elapsed * 1000) ms")
    }
}
