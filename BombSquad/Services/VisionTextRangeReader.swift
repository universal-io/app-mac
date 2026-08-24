import AppKit
import ApplicationServices

/// Text under the pointer, read without selecting anything.
///
/// The pointing overlay swallows every click, so the application under it
/// never sees the drag and never shows an I-beam or a selection of its own.
/// What the user sweeps has to be resolved by us — and the obvious API for
/// position → character index is a lie in the engine that matters most:
/// **Blink stubs `AXRangeForPosition` to zero.** Chrome and Electron return
/// index 0 for every point on every text run, and `AXNumberOfCharacters`
/// returns 0 against a run whose value holds fourteen characters (probed on
/// this machine, 2026-08-24; the first probe read "success" out of it because
/// every run's answer, 0, is also a valid index).
///
/// What Blink does implement, correctly and per character, is
/// `AXBoundsForRange`: the rectangle of any range, growing monotonically,
/// sub-millisecond («組» = 13×15px at the right screen position). So the
/// caret is found the other way around — binary-searching character
/// rectangles against the pointer — and the characters themselves come from
/// the run's `AXValue`, the one text attribute Blink fills in. The
/// application's own selection state and the clipboard stay untouched
/// throughout.
@MainActor
enum VisionTextRangeReader {
    /// Where a text gesture is anchored: the run whose text it is, that text
    /// read once at the press, and the caret the press landed on.
    ///
    /// The text is captured at the press on purpose: the run's value cannot
    /// change under the sweep without the user seeing the screen change, and
    /// slicing what was measured is the only way the swept string cannot
    /// disagree with the highlight that was shown.
    struct Anchor {
        let element: AXUIElement
        let text: String
        let caret: Int
    }

    /// Roles whose text these APIs answer for. A hit that stops at a container
    /// (web area, group) indexes the wrong document and measures degenerate
    /// 0×0 bounds — both shapes seen in the probe, not assumed.
    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField"]

    /// A run longer than this is not something a hand sweeps across; the wire
    /// encoder bounds what travels anyway, and binary-searching a document-
    /// sized value would spend its calls on nothing the user meant.
    private static let maxRunUnits = 12_000

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
    /// what is under the point is not text whose characters can be measured.
    static func anchor(at point: CGPoint, in application: AXUIElement) -> Anchor? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            application, Float(point.x), Float(point.y), &hit
        ) == .success, let hit else { return nil }
        guard let role = copyAttribute(hit, kAXRoleAttribute) as? String,
              textRoles.contains(role) else { return nil }
        guard let text = copyAttribute(hit, kAXValueAttribute) as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= maxRunUnits else { return nil }
        guard let caret = caretIndex(at: point, in: hit, units: text.utf16.count) else {
            return nil
        }
        return Anchor(element: hit, text: text, caret: caret)
    }

    /// The swept range from the anchor's caret to the caret under the current
    /// point, on the anchor's own run. A point past the run's edges clamps to
    /// its nearest end — the comparator sends it there — so sweeping off the
    /// text keeps selecting to the boundary instead of snapping away.
    static func range(from anchor: Anchor, to point: CGPoint) -> CFRange? {
        guard let caret = caretIndex(
            at: point, in: anchor.element, units: anchor.text.utf16.count
        ) else { return nil }
        return CFRange(
            location: min(anchor.caret, caret),
            length: abs(caret - anchor.caret)
        )
    }

    /// The exact characters of a swept range, sliced from the text measured at
    /// the press — the source the highlight was computed from, so the two
    /// cannot disagree.
    static func text(of range: CFRange, in anchor: Anchor) -> String? {
        guard range.length > 0 else { return nil }
        let units = Array(anchor.text.utf16)
        guard range.location >= 0, range.location + range.length <= units.count else {
            return nil
        }
        return String(utf16CodeUnits: Array(
            units[range.location ..< range.location + range.length]
        ), count: range.length)
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

    /// The caret position (0...units) nearest a point, found by binary search
    /// over per-character rectangles.
    ///
    /// Characters are ordered by line and then left to right, so one 2D
    /// comparator — later line means later index, same line falls back to the
    /// glyph's horizontal middle — keeps the search sound across wrapped runs.
    /// About log₂(units) calls at sub-millisecond each. A character whose
    /// rectangle cannot be measured (collapsed whitespace) borrows the nearest
    /// measurable neighbour's; a run where nothing measures returns nil and
    /// the gesture stays what it looked like.
    private static func caretIndex(
        at point: CGPoint,
        in element: AXUIElement,
        units: Int
    ) -> Int? {
        guard units > 0 else { return nil }
        var low = 0
        var high = units - 1
        var resolvedAny = false
        while low <= high {
            let middle = (low + high) / 2
            guard let (index, rect) = measurableCharacter(
                near: middle, within: low...high, in: element
            ) else { break }
            resolvedAny = true
            if point.y < rect.minY {
                high = index - 1
            } else if point.y > rect.maxY {
                low = index + 1
            } else if point.x < rect.midX {
                high = index - 1
            } else {
                low = index + 1
            }
        }
        return resolvedAny ? low : nil
    }

    /// The nearest character to `index` inside `window` whose rectangle
    /// actually measures.
    ///
    /// The scan is capped: eight unmeasurable characters in a row is not
    /// collapsed whitespace, it is an element that does not really answer this
    /// call, and against a hung one each failed attempt costs the messaging
    /// timeout. Giving up ends the search with whatever it has.
    private static func measurableCharacter(
        near index: Int,
        within window: ClosedRange<Int>,
        in element: AXUIElement
    ) -> (Int, CGRect)? {
        let reach = min(8, max(index - window.lowerBound, window.upperBound - index))
        for offset in 0...reach {
            for candidate in [index + offset, index - offset] where window.contains(candidate) {
                if let rect = bounds(of: CFRange(location: candidate, length: 1), in: element) {
                    return (candidate, rect)
                }
            }
        }
        return nil
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

    private static func axValue(_ range: CFRange) -> AXValue {
        var value = range
        return AXValueCreate(.cfRange, &value)!
    }
}
