import AppKit
import XCTest
@testable import Universal_IO

/// The mark is the only thing that tells the model where the user pointed (the
/// capture excludes this app, so the overlay's own ring never reaches the
/// model). These read the pixels rather than trusting the drawing calls: a mark
/// in the wrong place still compiles, and the failure it produces is an answer
/// about the wrong control.
final class VisionPointerMarkTests: XCTestCase {
    func testRingLandsOnThePointedSpotWithTheVerticalFlipApplied() throws {
        // Near the TOP of the image on purpose. Normalized space is top-left
        // origin and the drawing context is bottom-left, so an image marked at
        // y=0.1 with the flip missing gets its ring at y=0.9 — and every test
        // using a centred point would pass anyway.
        let bitmap = try white(width: 1000, height: 1000)
        let marked = try XCTUnwrap(
            VisionPointerMark.burn(
                VisionPointer(kind: .point(CGPoint(x: 0.25, y: 0.1))),
                into: bitmap
            )
        )

        // The crosshair passes through the exact spot.
        assertMarked(marked, x: 250, y: 100, "the pointed spot")
        // The ring itself, one radius (0.022 * 1000 = 22px) to the side.
        assertMarked(marked, x: 272, y: 100, "the ring's right edge")
        assertMarked(marked, x: 250, y: 78, "the ring's top edge")
        // The mirrored position must be untouched.
        assertUntouched(marked, x: 250, y: 900, "the vertically mirrored spot")
    }

    func testTheMarkIsARingRatherThanADiscSoTheTargetStaysVisible() throws {
        let bitmap = try white(width: 1000, height: 1000)
        let marked = try XCTUnwrap(
            VisionPointerMark.burn(
                VisionPointer(kind: .point(CGPoint(x: 0.5, y: 0.5))),
                into: bitmap
            )
        )
        // Inside the ring, off both crosshair arms: a filled dot would cover
        // this, and with it whatever the answer is about.
        assertUntouched(marked, x: 512, y: 512, "inside the ring, off the crosshair")
        assertMarked(marked, x: 522, y: 500, "the ring itself")
    }

    /// The mark carries its own edge outward: a dark band between the magenta
    /// core and the white surround.
    ///
    /// Two bands leave the mark defenceless on the two screens it is most likely
    /// to need help on — a white page hides the white surround, and a magenta or
    /// hot-pink one hides the core. Nothing throws when a band is dropped; the
    /// mark just quietly stops having an edge on somebody's brand page, so the
    /// band is pinned here.
    func testTheMarkCarriesADarkBandBetweenItsCoreAndItsSurround() throws {
        let bitmap = try white(width: 1000, height: 1000)
        let marked = try XCTUnwrap(
            VisionPointerMark.burn(
                VisionPointer(kind: .point(CGPoint(x: 0.5, y: 0.5))),
                into: bitmap
            )
        )

        // Straight out from the centre along the x axis, across every band.
        var sawMagenta = false
        var sawDark = false
        for x in 500...540 {
            guard let colour = marked.colorAt(x: x, y: 500) else { continue }
            let r = colour.redComponent, g = colour.greenComponent, b = colour.blueComponent
            if r > 0.6 && g < 0.4 && b > 0.6 { sawMagenta = true }
            if r < 0.35 && g < 0.35 && b < 0.35 { sawDark = true }
        }
        XCTAssertTrue(sawMagenta, "the magenta core is gone")
        XCTAssertTrue(sawDark, "the dark band between core and surround is gone")
    }

    func testTheRestOfTheScreenSurvivesUnchanged() throws {
        let bitmap = try white(width: 800, height: 600)
        let marked = try XCTUnwrap(
            VisionPointerMark.burn(
                VisionPointer(kind: .point(CGPoint(x: 0.5, y: 0.5))),
                into: bitmap
            )
        )
        XCTAssertEqual(marked.pixelsWide, 800)
        XCTAssertEqual(marked.pixelsHigh, 600)
        assertUntouched(marked, x: 20, y: 20, "the far corner")
        assertUntouched(marked, x: 780, y: 580, "the opposite corner")
    }

    func testRegionIsDrawnAsAFrameAroundTheAreaNotAcrossIt() throws {
        let bitmap = try white(width: 1000, height: 1000)
        let marked = try XCTUnwrap(
            VisionPointerMark.burn(
                VisionPointer(kind: .region(CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.2))),
                into: bitmap
            )
        )
        // Top edge of the region in top-left space is y = 200; left edge x = 200.
        assertMarked(marked, x: 400, y: 200, "the region's top edge")
        assertMarked(marked, x: 400, y: 400, "the region's bottom edge")
        assertMarked(marked, x: 200, y: 300, "the region's left edge")
        assertMarked(marked, x: 600, y: 300, "the region's right edge")
        // The enclosed area stays readable.
        assertUntouched(marked, x: 400, y: 300, "the middle of the region")
    }

    func testHandDrawnLoopIsBurnedAsThePathRatherThanItsBoundingBox() throws {
        let bitmap = try white(width: 1000, height: 1000)
        // A triangle inside the bounding box. Its bounding box would paint the
        // top-left corner; the path itself leaves that corner clear.
        let path = [
            CGPoint(x: 0.5, y: 0.2),
            CGPoint(x: 0.8, y: 0.8),
            CGPoint(x: 0.2, y: 0.8),
        ]
        let marked = try XCTUnwrap(
            VisionPointerMark.burn(
                VisionPointer(
                    kind: .region(CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)),
                    stroke: path
                ),
                into: bitmap
            )
        )
        assertMarked(marked, x: 500, y: 800, "the loop's base")
        assertMarked(marked, x: 500, y: 200, "the loop's apex")
        assertUntouched(marked, x: 210, y: 210, "the bounding box's empty corner")
    }

    func testStrokeWidthNeverFallsBelowTwoPixelsOnASmallImage() throws {
        // 0.004 * 200 = 0.8px, which would disappear. The floor exists so a
        // small capture still carries a visible mark.
        let bitmap = try white(width: 200, height: 200)
        let marked = try XCTUnwrap(
            VisionPointerMark.burn(
                VisionPointer(kind: .point(CGPoint(x: 0.5, y: 0.5))),
                into: bitmap
            )
        )
        assertMarked(marked, x: 100, y: 100, "the pointed spot on a small image")
    }

    // MARK: - The bytes that actually leave

    /// The mark has to survive the encode, not just the draw. This goes through
    /// the real wire path and reads the pixels back out of the base64 the
    /// Gateway would receive.
    func testTheEncodedImageCarriesTheMark() throws {
        let url = try writeWhitePNG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(at: url) }

        let encoded = try GatewayVisionClient.encodeForWire(
            url: url,
            pixelWidth: 800,
            pixelHeight: 600,
            captureRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            pointer: VisionPointer(kind: .point(CGPoint(x: 0.25, y: 0.25)))
        )
        let data = try XCTUnwrap(Data(base64Encoded: encoded.base64))
        let sent = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(sent.pixelsWide, 800)
        XCTAssertEqual(sent.pixelsHigh, 600)
        assertMarked(sent, x: 200, y: 150, "the pointed spot in the sent bytes")
        assertUntouched(sent, x: 600, y: 450, "the far side of the sent bytes")
    }

    /// Without a pointer the original bytes go through untouched, which is what
    /// keeps every existing turn byte-identical to before this feature existed.
    func testWithoutAPointerTheOriginalBytesArePassedThrough() throws {
        let url = try writeWhitePNG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try Data(contentsOf: url)

        let encoded = try GatewayVisionClient.encodeForWire(
            url: url,
            pixelWidth: 800,
            pixelHeight: 600,
            captureRect: CGRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertEqual(encoded.base64, source.base64EncodedString())
        XCTAssertEqual(encoded.mediaType, "image/png")
    }

    // MARK: - Helpers

    private func writeWhitePNG(width: Int, height: Int) throws -> URL {
        let bitmap = try white(width: width, height: height)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pointer-mark-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    private func white(width: Int, height: Int) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: width, height: height)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// Marked means "not the original white" — either the magenta line or the
    /// white halo's antialiased edge over it. Testing for the exact magenta
    /// would make the test a hostage of antialiasing.
    private func assertMarked(
        _ bitmap: NSBitmapImageRep,
        x: Int,
        y: Int,
        _ what: String,
        radius: Int = 3
    ) {
        XCTAssertTrue(
            anyPixel(in: bitmap, around: (x, y), radius: radius) { !isWhite($0) },
            "expected a mark at \(what) (\(x), \(y))"
        )
    }

    private func assertUntouched(
        _ bitmap: NSBitmapImageRep,
        x: Int,
        y: Int,
        _ what: String
    ) {
        let color = try? XCTUnwrap(bitmap.colorAt(x: x, y: y))
        XCTAssertTrue(
            color.map(isWhite) ?? false,
            "expected \(what) (\(x), \(y)) to be untouched, got \(String(describing: color))"
        )
    }

    private func anyPixel(
        in bitmap: NSBitmapImageRep,
        around centre: (x: Int, y: Int),
        radius: Int,
        where predicate: (NSColor) -> Bool
    ) -> Bool {
        for dx in -radius...radius {
            for dy in -radius...radius {
                let x = centre.x + dx
                let y = centre.y + dy
                guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
                      let color = bitmap.colorAt(x: x, y: y) else { continue }
                if predicate(color) { return true }
            }
        }
        return false
    }

    private func isWhite(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return false }
        return rgb.redComponent > 0.98 && rgb.greenComponent > 0.98 && rgb.blueComponent > 0.98
    }
}
