import AppKit
import ApplicationServices

/// Approved actions into the target app via Accessibility (master plan
/// stair 2: "what" from Vision, "where/how" from AX).
///
/// Design: no element handles are cached. The AI names the target by its
/// on-screen label ([[target:…]]); when the user approves, the tree is
/// searched fresh and the action runs on what exists NOW — a screen change
/// between answer and approval can therefore never fire a stale element.
/// Everything is budgeted like SituationalContextService so a huge or hung
/// AX tree cannot stall the app.
enum AXActionService {
    struct Actionable {
        let element: AXUIElement
        let role: String
        let label: String
        /// Global display coordinates (CG orientation, top-left origin) —
        /// same space as ScreenshotAttachment.captureRect.
        let frame: CGRect?
        let isTextInput: Bool
    }

    enum ActionError: LocalizedError {
        case notPermitted
        case notFound(String)
        case actionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notPermitted:
                return "アクセシビリティの許可が必要です。"
            case .notFound(let label):
                return "「\(label)」を画面上で見つけられませんでした。"
            case .actionFailed(let label):
                return "「\(label)」の操作に失敗しました。"
            }
        }
    }

    private enum Budget {
        static let maxNodes = 6000
        static let deadline: TimeInterval = 2.5
        static let axMessagingTimeout: Float = 0.25
    }

    private static let pressableRoles: Set<String> = [
        kAXButtonRole, "AXLink", kAXPopUpButtonRole, kAXCheckBoxRole,
        kAXRadioButtonRole, kAXMenuItemRole, kAXMenuButtonRole,
        "AXTab", kAXDisclosureTriangleRole,
    ]
    private static let textInputRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// Finds the best actionable element for an AI-named label, preferring
    /// candidates nearest to the model's own location estimate when several
    /// carry the same label (a menu item and a breadcrumb, say).
    static func findActionable(
        pid: pid_t,
        label: String,
        near globalRect: CGRect?
    ) async -> Actionable? {
        await Task.detached(priority: .userInitiated) {
            findActionableSync(pid: pid, label: label, near: globalRect)
        }.value
    }

    /// Presses the element matching the label and returns its frame (for
    /// visual feedback of where the press landed). Runs the search at
    /// approval time — never on a snapshot.
    ///
    /// A synthetic click at the element's position is PREFERRED over AXPress
    /// when the element is visible: web SPAs (GA4 et al.) sometimes accept
    /// AXPress without dispatching the DOM events their router listens to,
    /// reporting success while nothing happens. A real click is the same
    /// path a human takes. AXPress remains the route for off-screen or
    /// frameless elements.
    @discardableResult
    static func press(pid: pid_t, label: String, near globalRect: CGRect?) async throws -> CGRect? {
        guard AXIsProcessTrusted() else { throw ActionError.notPermitted }
        NSRunningApplication(processIdentifier: pid)?.activate()
        if let target = await findActionable(pid: pid, label: label, near: globalRect) {
            if let frame = target.frame, isOnScreen(frame),
               clickAt(CGPoint(x: frame.midX, y: frame.midY)) {
                return frame
            }
            let result = AXUIElementPerformAction(target.element, kAXPressAction as CFString)
            guard result == .success else {
                throw ActionError.actionFailed(label)
            }
            return target.frame
        }

        if let globalRect, isOnScreen(globalRect),
           clickAt(CGPoint(x: globalRect.midX, y: globalRect.midY)) {
            return globalRect
        }

        throw ActionError.notFound(label)
    }

    /// Whether a global CG rect is visible on any current display.
    private static func isOnScreen(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            guard let id = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else { return false }
            return CGDisplayBounds(id).intersects(frame)
        }
    }

    /// Focuses the text input matching the label (activating its app first)
    /// so a follow-up ⌘V synthesis lands in the right field.
    static func focusTextInput(pid: pid_t, label: String, near globalRect: CGRect?) async throws {
        guard AXIsProcessTrusted() else { throw ActionError.notPermitted }
        guard let target = await findActionable(pid: pid, label: label, near: globalRect),
              target.isTextInput || target.frame != nil
        else {
            throw ActionError.notFound(label)
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
        let result = AXUIElementSetAttributeValue(
            target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue
        )
        if result != .success {
            // Clicking into the field is the universal fallback.
            if let frame = target.frame, clickAt(CGPoint(x: frame.midX, y: frame.midY)) {
                return
            }
            throw ActionError.actionFailed(label)
        }
    }

    // MARK: - Search

    private static func findActionableSync(
        pid: pid_t,
        label: String,
        near globalRect: CGRect?
    ) -> Actionable? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Budget.axMessagingTimeout)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        let needle = matchKey(label)
        guard !needle.isEmpty else { return nil }

        let deadline = Date().addingTimeInterval(Budget.deadline)
        var visited = 0
        var stack: [AXUIElement] = [appElement]
        var hits: [(tier: Int, actionable: Actionable)] = []

        while let element = stack.popLast() {
            if visited >= Budget.maxNodes || Date() >= deadline { break }
            visited += 1

            let role = copyString(element, kAXRoleAttribute) ?? ""
            let pressable = pressableRoles.contains(role)
            let textInput = textInputRoles.contains(role)
            if pressable || textInput {
                let candidates = [
                    copyString(element, kAXTitleAttribute),
                    copyString(element, kAXDescriptionAttribute),
                    copyString(element, "AXLabel"),
                    textInput ? copyString(element, "AXPlaceholderValue") : nil,
                    pressable ? copyString(element, kAXValueAttribute) : nil,
                ]
                let tier = candidates.compactMap { candidate -> Int? in
                    guard let candidate else { return nil }
                    return matchTier(needle: needle, candidate: candidate)
                }.min()
                if let tier {
                    hits.append((tier, Actionable(
                        element: element,
                        role: role,
                        label: label,
                        frame: copyFrame(element),
                        isTextInput: textInput
                    )))
                }
            }

            if let children = copyChildren(element) {
                stack.append(contentsOf: children.reversed())
            }
        }

        // Exact label beats partial: a bare "ユーザー" section header must
        // never win over "ユーザーの環境の詳細" when the AI named the latter
        // (pressing the wrong one toggles menus shut — the 2026-07-06 bug).
        guard let bestTier = hits.map(\.tier).min() else { return nil }
        let finalists = hits.filter { $0.tier == bestTier }.map(\.actionable)
        guard let globalRect, finalists.count > 1 else { return finalists[0] }
        let center = CGPoint(x: globalRect.midX, y: globalRect.midY)
        return finalists.min { lhs, rhs in
            distance(lhs.frame, to: center) < distance(rhs.frame, to: center)
        }
    }

    /// Label-match quality: 0 = exact, 1 = candidate contains the label,
    /// 2 = partial (label contains the candidate). nil = no match. This must
    /// stay aligned with VisionSession's OCR ranking: the AI names WHAT and
    /// the device resolves WHERE.
    private static func matchTier(needle: String, candidate: String) -> Int? {
        let key = matchKey(candidate)
        guard !key.isEmpty else { return nil }
        if key == needle { return 0 }
        if key.contains(needle) { return 1 }
        if needle.contains(key), key.count >= 2 { return 2 }
        return nil
    }

    private static func distance(_ frame: CGRect?, to point: CGPoint) -> CGFloat {
        guard let frame else { return .greatestFiniteMagnitude }
        let dx = frame.midX - point.x
        let dy = frame.midY - point.y
        return dx * dx + dy * dy
    }

    private static func matchKey(_ text: String) -> String {
        text.lowercased().filter { !$0.isWhitespace }
    }

    /// Synthetic primary click in global display (CG) coordinates. Used only
    /// as a fallback when the AX action is refused but the position is known.
    private static func clickAt(_ point: CGPoint) -> Bool {
        guard
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                               mouseCursorPosition: point, mouseButton: .left),
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                             mouseCursorPosition: point, mouseButton: .left)
        else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - AX helpers

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func copyFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
            let positionRef, let sizeRef,
            CFGetTypeID(positionRef) == AXValueGetTypeID(),
            CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue((positionRef as! AXValue), .cgPoint, &position),
            AXValueGetValue((sizeRef as! AXValue), .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AnyObject]
        else { return nil }
        return array.compactMap { child in
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { return nil }
            return (child as! AXUIElement)
        }
    }
}
