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

    let selection: VisionSelectionContext?
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
            selection: nil,
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
        if snapshot.selection != nil || isMeaningfulSelectedElement(snapshot) {
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

    static func isMeaningfulSelectedElement(_ snapshot: AXFocusSnapshot) -> Bool {
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
        let selectionCandidates: [VisionSelectionCandidate]
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
        var selectionCandidates: [VisionSelectionCandidate] = []

        while pass < Budget.maxPasses, !Task.isCancelled {
            pass += 1
            let attempt = captureAttempt(
                appElement: appElement,
                deadline: min(expiry, Date().addingTimeInterval(Budget.perPassDeadline)),
                pass: pass
            )
            selectionCandidates.append(contentsOf: attempt.selectionCandidates)
            if snapshotQuality(attempt.snapshot) >= snapshotQuality(best) {
                best = attempt.snapshot
            }

            let hasSelection = hasAuthoritativeSelection(
                candidates: attempt.selectionCandidates,
                sawWebArea: attempt.sawWebArea,
                snapshot: attempt.snapshot
            )
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

        let resolvedText = VisionSelectionResolver.resolve(candidates: selectionCandidates)
        let resolvedSelection = resolvedText ?? (
            AXFocusLaunchDecision.isMeaningfulSelectedElement(best)
                ? VisionSelectionContext.accessibilityElement(
                    role: best.role,
                    label: best.label,
                    frame: best.frame
                )
                : nil
        )
        return AXFocusSnapshot(
            selection: resolvedSelection,
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

    /// A short inner fragment is not authoritative while a web document is
    /// still loading. Keep using the existing bounded retry window so a later
    /// pass can expose the document-wide selection. Native controls can settle
    /// on their direct text immediately.
    static func hasAuthoritativeSelection(
        candidates: [VisionSelectionCandidate],
        sawWebArea: Bool,
        snapshot: AXFocusSnapshot
    ) -> Bool {
        if AXFocusLaunchDecision.isMeaningfulSelectedElement(snapshot) { return true }
        if candidates.contains(where: { $0.scope == .document }) { return true }
        return !sawWebArea && !candidates.isEmpty
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
                selectionCandidates: [],
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
                    selection: nil,
                    role: nil,
                    label: nil,
                    frame: nil,
                    isEditable: false,
                    isSecureField: true,
                    isElementSelected: false,
                    status: .complete,
                    collectionPasses: pass
                ),
                selectionCandidates: [],
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
        var selectionCandidates: [VisionSelectionCandidate] = []
        var status: AXFocusSnapshot.CaptureStatus = .complete

        while visited < Budget.maxAncestorLevels, Date() < deadline {
            visited += 1
            let subrole = copyString(element, kAXSubroleAttribute).value
            if subrole == "AXSecureTextField" {
                return Attempt(
                    snapshot: AXFocusSnapshot(
                        selection: nil,
                        role: nil,
                        label: nil,
                        frame: nil,
                        isEditable: false,
                        isSecureField: true,
                        isElementSelected: false,
                        status: .complete,
                        collectionPasses: pass
                    ),
                    selectionCandidates: [],
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
                let evidence = selectedTextEvidence(element, directText: text)
                selectionCandidates.append(VisionSelectionCandidate(
                    directText: text,
                    role: role,
                    label: label(for: element),
                    containerFrame: copyFrame(element).value,
                    selectionFrames: evidence.frame.map { [$0] } ?? [],
                    scope: role == "AXWebArea" ? .document : (visited == 1 ? .focusedElement : .ancestor),
                    depth: visited - 1,
                    pass: pass,
                    rangeEvidence: evidence.rangeEvidence,
                    isSecure: false
                ))
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
        if !selectionCandidates.contains(where: { $0.scope == .document }),
           Date() < deadline {
            let documentResult = collectDocumentSelectionCandidates(
                appElement: appElement,
                deadline: deadline,
                pass: pass,
                startingDepth: visited
            )
            selectionCandidates.append(contentsOf: documentResult.candidates)
            visited += documentResult.visitedNodes
            sawWebArea = sawWebArea || documentResult.sawWebArea
        }
        if Date() >= deadline, selectionCandidates.isEmpty {
            status = .timedOut
        }

        let probe = probeTree(appElement: appElement)
        return Attempt(
            snapshot: AXFocusSnapshot(
                selection: VisionSelectionResolver.resolve(candidates: selectionCandidates),
                role: focusedRole,
                label: focusedLabel,
                frame: focusedFrame,
                isEditable: editable,
                isSecureField: false,
                isElementSelected: focusedSelected,
                status: status,
                collectionPasses: pass
            ),
            selectionCandidates: selectionCandidates,
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
        if snapshot.selection?.kind == .text { return 4 }
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

    private struct SelectedTextEvidence {
        let rangeEvidence: VisionSelectionCandidate.RangeEvidence
        let frame: CGRect?
    }

    private struct DocumentSelectionResult {
        let candidates: [VisionSelectionCandidate]
        let visitedNodes: Int
        let sawWebArea: Bool
    }

    private static func collectDocumentSelectionCandidates(
        appElement: AXUIElement,
        deadline: Date,
        pass: Int,
        startingDepth: Int
    ) -> DocumentSelectionResult {
        guard let window = copyElement(appElement, kAXFocusedWindowAttribute).value else {
            return DocumentSelectionResult(candidates: [], visitedNodes: 0, sawWebArea: false)
        }
        var candidates: [VisionSelectionCandidate] = []
        var stack: [AXUIElement] = [window]
        var visited = 0
        var sawWebArea = false
        while let element = stack.popLast(), visited < 256, Date() < deadline {
            visited += 1
            let subrole = copyString(element, kAXSubroleAttribute).value
            if subrole == "AXSecureTextField" { continue }
            let role = copyString(element, kAXRoleAttribute).value
            if role == "AXWebArea" {
                sawWebArea = true
                let selectedTextRead = copyString(element, kAXSelectedTextAttribute)
                if let text = normalizedSelectedText(selectedTextRead.value) {
                    let evidence = selectedTextEvidence(element, directText: text)
                    candidates.append(VisionSelectionCandidate(
                        directText: text,
                        role: role,
                        label: label(for: element),
                        containerFrame: copyFrame(element).value,
                        selectionFrames: evidence.frame.map { [$0] } ?? [],
                        scope: .document,
                        depth: startingDepth + visited,
                        pass: pass,
                        rangeEvidence: evidence.rangeEvidence,
                        isSecure: false
                    ))
                }
            }
            if let children = copyChildren(element) {
                stack.append(contentsOf: children.reversed())
            }
        }
        return DocumentSelectionResult(
            candidates: candidates,
            visitedNodes: visited,
            sawWebArea: sawWebArea
        )
    }

    private static func selectedTextEvidence(
        _ element: AXUIElement,
        directText: String
    ) -> SelectedTextEvidence {
        let rangeRead = copyValue(element, kAXSelectedTextRangeAttribute)
        guard let rangeValue = rangeRead.value,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return SelectedTextEvidence(rangeEvidence: .unavailable, frame: nil)
        }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.length > 0 else {
            return SelectedTextEvidence(rangeEvidence: .unavailable, frame: nil)
        }

        var rangeStringValue: CFTypeRef?
        let rangeStringError = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &rangeStringValue
        )
        let rangeString = rangeStringError == .success
            ? normalizedSelectedText(rangeStringValue as? String)
            : nil
        let rangeEvidence: VisionSelectionCandidate.RangeEvidence
        if let rangeString {
            rangeEvidence = rangeString == directText ? .matching : .mismatching
        } else {
            rangeEvidence = .unavailable
        }

        var boundsValue: CFTypeRef?
        let boundsError = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        )
        var bounds = CGRect.zero
        let frame: CGRect?
        if boundsError == .success,
           let boundsValue,
           CFGetTypeID(boundsValue) == AXValueGetTypeID(),
           AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds),
           bounds.width > 0,
           bounds.height > 0 {
            frame = bounds
        } else {
            frame = nil
        }
        return SelectedTextEvidence(rangeEvidence: rangeEvidence, frame: frame)
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

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement]? {
        let read = copyValue(element, kAXChildrenAttribute)
        guard let array = read.value as? [AnyObject] else { return nil }
        return array.compactMap { child in
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { return nil }
            return (child as! AXUIElement)
        }
    }
}
