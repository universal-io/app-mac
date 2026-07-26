import AppKit
import ApplicationServices

/// Collects the L1 situational context (frontmost app, window title, and the
/// conversation text around the focused field) via the Accessibility API.
///
/// Timing: the frontmost app must be identified BEFORE our panel activates and
/// steals focus, so `captureTask()` reads it synchronously and then walks the
/// AX tree of that pid in the background. The per-app AX tree stays queryable
/// after our panel becomes key, so only the pid lookup is timing-sensitive.
///
/// Search strategy: walking a whole window from the top spends the budget on
/// chrome (sidebars, toolbars) before ever reaching the conversation — in
/// Slack that yields the channel list instead of the messages. Instead the
/// walk expands outward from the focused input field: parent by parent, the
/// conversation pane around the input is reached long before window chrome.
/// The window-level walk remains only as a last resort.
///
/// All walks are budgeted (node count, character count, wall-clock deadline)
/// so a huge or unresponsive AX tree can never stall a review.
enum SituationalContextService {
    private enum Budget {
        static let maxNodesPerWalk = 4000
        static let maxCollectedChars = 8000
        /// Final excerpt keeps the TAIL of the collected text: conversations
        /// render newest messages at the bottom, which is what matters.
        static let maxExcerptChars = 2500
        /// Enough conversation text to stop expanding the search scope.
        static let sufficientChars = 400
        /// How many ancestor levels to climb from the focused field.
        static let maxClimbLevels = 8
        /// Overall wall-clock deadline for the whole collection.
        static let deadline: TimeInterval = 2.0
        /// Per-message AX timeout so one hung app can't eat the whole deadline.
        static let axMessagingTimeout: Float = 0.25
        /// Electron builds its AX tree lazily after AXManualAccessibility is
        /// set; wait this long before the one retry when the first pass is empty.
        static let electronRetryDelay: useconds_t = 300_000
    }

    /// Kick off a capture of whatever app is frontmost right now. Returns a
    /// task resolving to nil when capture is disabled, not permitted, or the
    /// frontmost app is ourselves.
    static func captureTask() -> Task<SituationalContext?, Never> {
        guard AppSettings.isContextCaptureEnabled(), AXIsProcessTrusted() else {
            return Task { nil }
        }
        guard
            let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return Task { nil }
        }

        let pid = app.processIdentifier
        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let bundleID = app.bundleIdentifier

        return Task.detached(priority: .userInitiated) {
            capture(pid: pid, appName: appName, bundleID: bundleID)
        }
    }

    // MARK: - Capture

    private static func capture(pid: pid_t, appName: String, bundleID: String?) -> SituationalContext? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Budget.axMessagingTimeout)

        // Electron apps expose their AX tree lazily; this documented attribute
        // asks them to build it even when no system AT is running. Harmless
        // (returns an error) everywhere else.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var window = copyElement(appElement, kAXFocusedWindowAttribute)
        var windowTitle = window.flatMap { copyString($0, kAXTitleAttribute) }
        var excerpt = collectConversation(appElement: appElement, window: window)

        // One retry after a beat: the first pass right after enabling
        // AXManualAccessibility often races the tree construction in Electron.
        if excerpt == nil {
            usleep(Budget.electronRetryDelay)
            window = copyElement(appElement, kAXFocusedWindowAttribute)
            windowTitle = window.flatMap { copyString($0, kAXTitleAttribute) } ?? windowTitle
            excerpt = collectConversation(appElement: appElement, window: window)
        }

        let focused = copyElement(appElement, kAXFocusedUIElementAttribute)
        let focusedFieldEditable = focused.map { editableVerdict($0).isEditable } ?? false
        let host = window.flatMap { BrowserHostLookup.host(in: $0) }

        // App identity alone still tells the review where the draft is going,
        // so a context without conversation text is still worth returning.
        return SituationalContext(
            appName: appName,
            bundleID: bundleID,
            pid: pid,
            windowTitle: windowTitle,
            host: host,
            conversationExcerpt: excerpt,
            focusedFieldEditable: focusedFieldEditable,
            capturedAt: Date()
        )
    }

    /// Synchronous, fast check of whether the given app currently has an
    /// editable text field focused. Read this at summon *before* our panel
    /// activates — once our window becomes key the source app resigns first
    /// responder and its `kAXFocusedUIElementAttribute` no longer reports the
    /// field, which is exactly why the async context walk saw no focus. One
    /// focused-element read (+ role/subrole), so it is safe on the hot path.
    static func focusedFieldIsEditable(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted(),
              pid != ProcessInfo.processInfo.processIdentifier else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Budget.axMessagingTimeout)
        guard let focused = copyElement(appElement, kAXFocusedUIElementAttribute) else {
            FocusGateTrace.log("no focused element")
            return false
        }
        let verdict = editableVerdict(focused)
        FocusGateTrace.log(verdict.description)
        return verdict.isEditable
    }

    /// Why the gate decided what it decided. Recorded because the decision is
    /// invisible in the product: compose opening on a screen with no visible
    /// input field is indistinguishable, from the outside, from a screen where
    /// something offscreen or non-textual held focus. Guessing between those
    /// from the resulting draft is not evidence — this is.
    struct FocusVerdict {
        let isEditable: Bool
        let matched: String
        let role: String
        let subrole: String
        let size: CGSize?
        let position: CGPoint?

        /// Shape only: role, subrole, geometry. Never the field's value — that
        /// is the user's content, and a diagnostic has no business holding it.
        var description: String {
            let frame = size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
            let origin = position.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "(?)"
            return "editable=\(isEditable) matched=\(matched) role=\(role.isEmpty ? "-" : role) "
                + "subrole=\(subrole.isEmpty ? "-" : subrole) size=\(frame) pos=\(origin)"
        }
    }

    /// Whether the focused element is an editable text control we could
    /// responsibly propose text for. Secure (password) fields are never
    /// eligible — the proactive suggestion must not target them.
    static func editableVerdict(_ element: AXUIElement) -> FocusVerdict {
        let subrole = copyString(element, kAXSubroleAttribute) ?? ""
        let role = copyString(element, kAXRoleAttribute) ?? ""
        let size = copySize(element, kAXSizeAttribute)
        let position = copyPoint(element, kAXPositionAttribute)

        func verdict(_ isEditable: Bool, _ matched: String) -> FocusVerdict {
            FocusVerdict(
                isEditable: isEditable,
                matched: matched,
                role: role,
                subrole: subrole,
                size: size,
                position: position
            )
        }

        if subrole == "AXSecureTextField" { return verdict(false, "secureField") }
        if subrole == "AXSearchField" { return verdict(true, "searchField") }
        if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
            return verdict(true, "textRole")
        }

        // Web/other text-ish controls: a settable string value is a generic
        // signal of an editable field. It is also the loosest rule here, which
        // is why the trace names it separately from a real text role.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue,
           copyString(element, kAXValueAttribute) != nil {
            return verdict(true, "settableValue")
        }
        return verdict(false, "none")
    }

    private static func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAXValue(element, attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func copyPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAXValue(element, attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }

    /// Expanding-scope search: collect text at each ancestor level of the
    /// focused field, stopping as soon as a scope yields enough conversation
    /// text. Falls back to the whole focused window when the climb found
    /// little (no focused element, or a sparse tree).
    private static func collectConversation(appElement: AXUIElement, window: AXUIElement?) -> String? {
        let deadline = Date().addingTimeInterval(Budget.deadline)
        let focused = copyElement(appElement, kAXFocusedUIElementAttribute)
        var best: String?

        if let focused {
            var scope = focused
            for _ in 0..<Budget.maxClimbLevels {
                guard Date() < deadline, let parent = copyElement(scope, kAXParentAttribute) else { break }
                scope = parent
                if let text = collectText(from: scope, excluding: focused, deadline: deadline) {
                    best = text
                    if text.count >= Budget.sufficientChars { return text }
                }
            }
        }

        if (best?.count ?? 0) < Budget.sufficientChars, let window, Date() < deadline {
            if let text = collectText(from: window, excluding: focused, deadline: deadline),
               text.count > (best?.count ?? 0) {
                best = text
            }
        }
        return best
    }

    /// Depth-first walk in document order, gathering readable text. The focused
    /// element's own value is skipped (it is the user's draft, sent separately)
    /// and secure fields are never read.
    private static func collectText(
        from root: AXUIElement,
        excluding focused: AXUIElement?,
        deadline: Date
    ) -> String? {
        var visited = 0
        var pieces: [String] = []
        // Global (not just adjacent) dedupe: list UIs repeat the same label
        // dozens of times ("連絡先候補" / "オフライン" per contact row in Gmail),
        // drowning the conversation. Dropping repeated identical strings loses
        // little for context purposes and cuts that noise generically.
        var seen = Set<String>()
        var collectedChars = 0
        var stack: [AXUIElement] = [root]

        while let element = stack.popLast() {
            if visited >= Budget.maxNodesPerWalk { break }
            if collectedChars >= Budget.maxCollectedChars { break }
            if Date() >= deadline { break }
            visited += 1

            // Secure fields are exposed as subrole AXSecureTextField; never read them.
            let subrole = copyString(element, kAXSubroleAttribute) ?? ""
            let isFocusedElement = focused.map { CFEqual($0, element) } ?? false

            if subrole != "AXSecureTextField", !isFocusedElement {
                if let value = copyString(element, kAXValueAttribute) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                        pieces.append(trimmed)
                        collectedChars += trimmed.count
                    }
                }
            }

            if let children = copyChildren(element) {
                // Reversed so the DFS pops children in document order.
                stack.append(contentsOf: children.reversed())
            }
        }

        let joined = pieces.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        return String(joined.suffix(Budget.maxExcerptChars))
    }

    // MARK: - AX helpers

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
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

/// Debug-only trace for the compose-versus-vision gate. Compose opening on a
/// screen with no visible input field has been reported and cannot be explained
/// from the outside: the draft the model produced is its reading of the screen,
/// not a record of which element held Accessibility focus. This log is that
/// record. Shape only — role, subrole, geometry, and which rule matched. Never
/// the field's contents.
enum FocusGateTrace {
    static func log(_ message: String) {
        #if DEBUG
        NSLog("[FocusGate] %@", message)
        #endif
    }
}
