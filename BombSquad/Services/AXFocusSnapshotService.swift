import AppKit
import ApplicationServices

/// A value-only view of Accessibility focus at summon time.
///
/// The AX element references are deliberately consumed inside the capture task
/// and never escape it. This makes one snapshot the sole input to the eventual
/// Focused Vision / Compose / Vision decision and prevents separate AX walks
/// from observing different focus states.
struct AXFocusSnapshot: Equatable {
    enum CaptureStatus: Equatable {
        case complete
        case permissionDenied
        case invalidTarget
        case noFocusedElement
        case timedOut
        case invalidatedElement
    }

    let selectedText: String?
    let role: String?
    let label: String?
    let frame: CGRect?
    let isEditable: Bool
    let isSecureField: Bool
    let isElementSelected: Bool
    let status: CaptureStatus
    let collectionPasses: Int

    static func unavailable(_ status: CaptureStatus, collectionPasses: Int = 0) -> Self {
        Self(
            selectedText: nil,
            role: nil,
            label: nil,
            frame: nil,
            isEditable: false,
            isSecureField: false,
            isElementSelected: false,
            status: status,
            collectionPasses: collectionPasses
        )
    }
}

/// Pure launch decision kept separate from AX reads so all precedence rules are
/// exhaustively tested and the production summon path observes one focus state.
enum AXFocusLaunchDecision {
    enum Destination: Equatable {
        case focusedVision
        case compose
        case vision
    }

    static func destination(for snapshot: AXFocusSnapshot) -> Destination {
        guard !snapshot.isSecureField else { return .vision }
        let hasSelectedText = snapshot.selectedText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        if hasSelectedText || isMeaningfulSelectedElement(snapshot) {
            return .focusedVision
        }
        return snapshot.isEditable ? .compose : .vision
    }

    /// When a non-secure AX read produced no target, Vision may inspect the
    /// capture for a visible selection highlight. The prompt remains
    /// best-effort and falls back to ordinary full-screen reading.
    static func shouldLookForVisualSelection(in snapshot: AXFocusSnapshot) -> Bool {
        guard destination(for: snapshot) == .vision, !snapshot.isSecureField else {
            return false
        }
        switch snapshot.status {
        case .permissionDenied, .invalidTarget:
            return false
        case .complete, .noFocusedElement, .timedOut, .invalidatedElement:
            return true
        }
    }

    private static func isMeaningfulSelectedElement(_ snapshot: AXFocusSnapshot) -> Bool {
        guard snapshot.isElementSelected, let role = snapshot.role else { return false }
        return ![
            "AXApplication", "AXWindow", "AXSheet", "AXGroup", "AXScrollArea",
            "AXSplitterGroup", "AXWebArea", "AXUnknown",
        ].contains(role)
    }
}

/// The bounded-retry rule is also pure. It mirrors the existing Vision identity
/// collection: cold/growing web trees get another pass, while native trees stop
/// as soon as their node count stabilizes.
enum AXFocusSnapshotRetryPolicy {
    static func shouldRetry(
        pass: Int,
        maxPasses: Int,
        beforeExpiry: Bool,
        hasSelection: Bool,
        hasFocusedElement: Bool,
        sawWebArea: Bool,
        visitedNodes: Int,
        previousVisitedNodes: Int
    ) -> Bool {
        guard pass < maxPasses, beforeExpiry, !hasSelection else { return false }
        if !hasFocusedElement {
            return true
        }
        let stillGrowing = Double(visitedNodes) > Double(previousVisitedNodes) * 1.25
        return sawWebArea || stillGrowing
    }
}

/// Reads focused element metadata and the nearest non-empty ancestor selection
/// in one bounded operation. The coordinator starts this task beside screen
/// capture, before Universal I/O activates its own panel.
enum AXFocusSnapshotService {
    private enum Budget {
        // Keep these aligned with VisionObservationCaptureService.IdentityBudget.
        static let maxPasses = 6
        static let totalDeadline: TimeInterval = 2.0
        static let passWaitNanoseconds: UInt64 = 250_000_000
        static let axMessagingTimeout: Float = 0.1
        static let maxAncestorLevels = 16
        static let perPassDeadline: TimeInterval = 1.0
    }

    private struct Attempt {
        let snapshot: AXFocusSnapshot
        let hasFocusedElement: Bool
        let sawWebArea: Bool
        let visitedNodes: Int
    }

    static func snapshotTask(pid: pid_t) -> Task<AXFocusSnapshot, Never> {
        guard AXIsProcessTrusted() else {
            return Task { .unavailable(.permissionDenied) }
        }
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else {
            return Task { .unavailable(.invalidTarget) }
        }

        return Task.detached(priority: .userInitiated) {
            await capture(pid: pid)
        }
    }

    private static func capture(pid: pid_t) async -> AXFocusSnapshot {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, Budget.axMessagingTimeout)

        // Electron and Chromium use different switches. Vision capture already
        // sets both before sustained bounded queries; use the same preparation.
        AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        AXUIElementSetAttributeValue(
            appElement,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )

        let expiry = Date().addingTimeInterval(Budget.totalDeadline)
        var pass = 0
        var previousVisitedNodes = 0
        var best = AXFocusSnapshot.unavailable(.noFocusedElement)

        while pass < Budget.maxPasses, !Task.isCancelled {
            pass += 1
            let attempt = captureAttempt(
                appElement: appElement,
                deadline: min(expiry, Date().addingTimeInterval(Budget.perPassDeadline)),
                pass: pass
            )
            if snapshotQuality(attempt.snapshot) >= snapshotQuality(best) {
                best = attempt.snapshot
            }

            let hasSelection = attempt.snapshot.selectedText != nil
                || attempt.snapshot.isElementSelected
            let retry = AXFocusSnapshotRetryPolicy.shouldRetry(
                pass: pass,
                maxPasses: Budget.maxPasses,
                beforeExpiry: Date() < expiry,
                hasSelection: hasSelection,
                hasFocusedElement: attempt.hasFocusedElement,
                sawWebArea: attempt.sawWebArea,
                visitedNodes: attempt.visitedNodes,
                previousVisitedNodes: previousVisitedNodes
            )
            previousVisitedNodes = attempt.visitedNodes
            guard retry else { break }
            try? await Task.sleep(nanoseconds: Budget.passWaitNanoseconds)
        }

        return AXFocusSnapshot(
            selectedText: best.selectedText,
            role: best.role,
            label: best.label,
            frame: best.frame,
            isEditable: best.isEditable,
            isSecureField: best.isSecureField,
            isElementSelected: best.isElementSelected,
            status: best.status,
            collectionPasses: pass
        )
    }

    private static func captureAttempt(
        appElement: AXUIElement,
        deadline: Date,
        pass: Int
    ) -> Attempt {
        let focusedRead = copyElement(appElement, kAXFocusedUIElementAttribute)
        guard let focused = focusedRead.value else {
            let status = captureStatus(for: focusedRead.error, deadline: deadline)
            let probe = probeTree(appElement: appElement)
            return Attempt(
                snapshot: .unavailable(status, collectionPasses: pass),
                hasFocusedElement: false,
                sawWebArea: probe.sawWebArea,
                visitedNodes: probe.visitedNodes
            )
        }

        let focusedSubrole = copyString(focused, kAXSubroleAttribute).value
        if focusedSubrole == "AXSecureTextField" {
            // Do not read labels, values, selection, or geometry from a secure
            // field. Its presence only forces a safe normal-Vision fallback.
            return Attempt(
                snapshot: AXFocusSnapshot(
                    selectedText: nil,
                    role: nil,
                    label: nil,
                    frame: nil,
                    isEditable: false,
                    isSecureField: true,
                    isElementSelected: false,
                    status: .complete,
                    collectionPasses: pass
                ),
                hasFocusedElement: true,
                sawWebArea: false,
                visitedNodes: 1
            )
        }

        let focusedRole = copyString(focused, kAXRoleAttribute).value
        let focusedLabel = label(for: focused)
        let focusedFrame = copyFrame(focused).value
        let focusedSelected = copyBool(focused, kAXSelectedAttribute).value ?? false
        let editable = isEditable(focused, role: focusedRole, subrole: focusedSubrole)

        var element = focused
        var visited = 0
        var sawWebArea = focusedRole == "AXWebArea"
        var selectedText: String?
        var selectionRole: String?
        var selectionLabel: String?
        var selectionFrame: CGRect?
        var status: AXFocusSnapshot.CaptureStatus = .complete

        while visited < Budget.maxAncestorLevels, Date() < deadline {
            visited += 1
            let subrole = copyString(element, kAXSubroleAttribute).value
            if subrole == "AXSecureTextField" {
                return Attempt(
                    snapshot: AXFocusSnapshot(
                        selectedText: nil,
                        role: nil,
                        label: nil,
                        frame: nil,
                        isEditable: false,
                        isSecureField: true,
                        isElementSelected: false,
                        status: .complete,
                        collectionPasses: pass
                    ),
                    hasFocusedElement: true,
                    sawWebArea: sawWebArea,
                    visitedNodes: visited
                )
            }
            let role = copyString(element, kAXRoleAttribute).value
            sawWebArea = sawWebArea || role == "AXWebArea"

            let selectedTextRead = copyString(element, kAXSelectedTextAttribute)
            if selectedTextRead.error == .cannotComplete {
                status = .timedOut
                break
            }
            if selectedTextRead.error == .invalidUIElement {
                status = .invalidatedElement
                break
            }
            if let text = normalizedSelectedText(selectedTextRead.value) {
                selectedText = text
                selectionRole = role
                selectionLabel = label(for: element)
                selectionFrame = selectedTextFrame(element) ?? copyFrame(element).value
                break
            }

            let parentRead = copyElement(element, kAXParentAttribute)
            guard let parent = parentRead.value else {
                if parentRead.error == .invalidUIElement {
                    status = .invalidatedElement
                } else if parentRead.error == .cannotComplete {
                    status = .timedOut
                }
                break
            }
            element = parent
        }
        if Date() >= deadline, selectedText == nil {
            status = .timedOut
        }

        let probe = probeTree(appElement: appElement)
        return Attempt(
            snapshot: AXFocusSnapshot(
                selectedText: selectedText,
                role: selectionRole ?? focusedRole,
                label: selectionLabel ?? focusedLabel,
                frame: selectionFrame ?? focusedFrame,
                isEditable: editable,
                isSecureField: false,
                isElementSelected: focusedSelected,
                status: status,
                collectionPasses: pass
            ),
            hasFocusedElement: true,
            sawWebArea: sawWebArea || probe.sawWebArea,
            visitedNodes: max(visited, probe.visitedNodes)
        )
    }

    private static func probeTree(appElement: AXUIElement) -> BrowserHostLookup.Probe {
        guard let window = copyElement(appElement, kAXFocusedWindowAttribute).value else {
            return BrowserHostLookup.Probe(host: nil, sawWebArea: false, visitedNodes: 0)
        }
        return BrowserHostLookup.probe(in: window)
    }

    private static func snapshotQuality(_ snapshot: AXFocusSnapshot) -> Int {
        if snapshot.selectedText != nil { return 4 }
        if snapshot.isSecureField { return 3 }
        if snapshot.role != nil { return 2 }
        return snapshot.status == .noFocusedElement ? 0 : 1
    }

    private static func captureStatus(
        for error: AXError,
        deadline: Date
    ) -> AXFocusSnapshot.CaptureStatus {
        if Date() >= deadline || error == .cannotComplete { return .timedOut }
        if error == .invalidUIElement { return .invalidatedElement }
        return .noFocusedElement
    }

    private static func normalizedSelectedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func label(for element: AXUIElement) -> String? {
        [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            "AXLabel",
            "AXPlaceholderValue",
        ].compactMap { copyString(element, $0).value?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func isEditable(
        _ element: AXUIElement,
        role: String?,
        subrole: String?
    ) -> Bool {
        if subrole == "AXSecureTextField" { return false }
        if subrole == "AXSearchField" { return true }
        if role == "AXTextField" || role == "AXTextArea" || role == "AXComboBox" {
            return true
        }

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            return false
        }
        let value = copyValue(element, kAXValueAttribute).value
        return value.map { CFGetTypeID($0) == CFStringGetTypeID() } ?? false
    }

    private static func selectedTextFrame(_ element: AXUIElement) -> CGRect? {
        let rangeRead = copyValue(element, kAXSelectedTextRangeAttribute)
        guard let rangeValue = rangeRead.value,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.length > 0 else {
            return nil
        }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success,
        let boundsValue,
        CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }
        var bounds = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds),
              bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        return bounds
    }

    private struct Read<Value> {
        let value: Value?
        let error: AXError
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> Read<CFTypeRef> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return Read(value: error == .success ? value : nil, error: error)
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> Read<AXUIElement> {
        let read = copyValue(element, attribute)
        guard let value = read.value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return Read(value: nil, error: read.error)
        }
        return Read(value: (value as! AXUIElement), error: read.error)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> Read<String> {
        let read = copyValue(element, attribute)
        return Read(value: read.value as? String, error: read.error)
    }

    private static func copyBool(_ element: AXUIElement, _ attribute: String) -> Read<Bool> {
        let read = copyValue(element, attribute)
        if let value = read.value as? Bool {
            return Read(value: value, error: read.error)
        }
        if let value = read.value as? NSNumber {
            return Read(value: value.boolValue, error: read.error)
        }
        return Read(value: nil, error: read.error)
    }

    private static func copyFrame(_ element: AXUIElement) -> Read<CGRect> {
        let positionRead = copyValue(element, kAXPositionAttribute)
        let sizeRead = copyValue(element, kAXSizeAttribute)
        guard let positionValue = positionRead.value,
              let sizeValue = sizeRead.value,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            let error = positionRead.error != .success ? positionRead.error : sizeRead.error
            return Read(value: nil, error: error)
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return Read(value: nil, error: .failure)
        }
        return Read(value: CGRect(origin: position, size: size), error: .success)
    }
}
