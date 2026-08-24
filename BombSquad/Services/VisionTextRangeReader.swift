import AppKit
import ApplicationServices

/// Text under the pointer, read without selecting anything.
///
/// The pointing overlay swallows every click, so the application under it
/// never sees the drag and never shows an I-beam or a selection of its own.
/// What the user sweeps has to be resolved by us: position → character index
/// (`AXRangeForPosition`), index range → string (`AXStringForRange`) and
/// on-screen rectangle (`AXBoundsForRange`). The application's own selection
/// state and the clipboard stay untouched throughout.
///
/// Probed on this machine before being built (2026-08-24): Chrome (Gmail) and
/// VS Code answer the whole chain in sub-millisecond calls, returning real
/// glyphs («わ», 17×20px) — but only from text-bearing roles. A hit that stops
/// at `AXWebArea` answers `AXRangeForPosition` with index 0 and degenerate
/// 0×0 bounds, which is why the role gate and the bounds validation below are
/// not defensive extras: the probe saw both failure shapes.
@MainActor
enum VisionTextRangeReader {
    /// Where a text gesture is anchored: the element whose text it is, and the
    /// character index under the point where the press happened.
    struct Anchor {
        let element: AXUIElement
        let index: Int
    }

    /// Roles whose text these APIs answer for. A hit on a container (web area,
    /// group) can still return an index, but it indexes the wrong document and
    /// its bounds come back degenerate — measured, not assumed.
    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField"]

    /// A sweep cannot mean more than this many UTF-16 units; the wire encoder
    /// bounds what travels anyway, and an unbounded `AXStringForRange` against
    /// a whole document is the one call in this chain that could stall.
    private static let maxSweepUnits = 12_000

    /// The application, wrapped once per pointing session.
    ///
    /// The messaging timeout matters more than the wrapping: these calls run
    /// on the main actor between mouse events, and the default timeout lets a
    /// hung application hold the overlay for seconds. A tenth of a second
    /// turns that into a missed hover.
    static func application(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        return app
    }

    /// The text anchor at a point (CG global, top-left origin), or nil when
    /// what is under the point is not text these APIs can index.
    static func anchor(at point: CGPoint, in application: AXUIElement) -> Anchor? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            application, Float(point.x), Float(point.y), &hit
        ) == .success, let hit else { return nil }
        guard let role = copyAttribute(hit, kAXRoleAttribute) as? String,
              textRoles.contains(role) else { return nil }
        guard let index = characterIndex(at: point, in: hit) else { return nil }
        return Anchor(element: hit, index: index)
    }

    /// The swept range from the anchor to the current point, on the anchor's
    /// own element. Nil when the current point no longer resolves to an index
    /// there — sweeping off the paragraph keeps the last resolvable range
    /// alive at the call site rather than snapping the highlight away.
    static func range(from anchor: Anchor, to point: CGPoint) -> CFRange? {
        guard let current = characterIndex(at: point, in: anchor.element) else { return nil }
        let location = min(anchor.index, current)
        let length = min(abs(current - anchor.index), maxSweepUnits)
        return CFRange(location: location, length: length)
    }

    /// The exact characters in a range.
    static func text(of range: CFRange, in element: AXUIElement) -> String? {
        guard range.length > 0 else { return nil }
        return copyParameterized(element, "AXStringForRange", axValue(range)) as? String
    }

    /// Where a range sits on screen (CG global), or nil when the answer is
    /// degenerate — whitespace-only runs and container-level indexing both
    /// come back as 0×0 rather than as errors.
    static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        guard range.length > 0,
              let value = copyParameterized(element, "AXBoundsForRange", axValue(range))
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect),
              rect.width >= 1, rect.height >= 1 else { return nil }
        return rect
    }

    private static func characterIndex(at point: CGPoint, in element: AXUIElement) -> Int? {
        guard let value = copyParameterized(element, "AXRangeForPosition", axValue(point))
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return error == .success ? value : nil
    }

    private static func copyParameterized(
        _ element: AXUIElement,
        _ name: String,
        _ parameter: CFTypeRef
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, name as CFString, parameter, &value
        )
        return error == .success ? value : nil
    }

    private static func axValue(_ point: CGPoint) -> AXValue {
        var value = point
        return AXValueCreate(.cgPoint, &value)!
    }

    private static func axValue(_ range: CFRange) -> AXValue {
        var value = range
        return AXValueCreate(.cfRange, &value)!
    }
}
