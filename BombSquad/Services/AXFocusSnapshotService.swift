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
            status: status,
            collectionPasses: collectionPasses
        )
    }
}

/// Pure launch decision kept separate from AX reads so all precedence rules are
/// exhaustively tested and the production summon path observes one focus state.
enum AXFocusLaunchDecision {
    enum Destination: Equatable {
        case compose
        case vision
    }

    static func destination(for snapshot: AXFocusSnapshot) -> Destination {
        guard !snapshot.isSecureField else { return .vision }
        if snapshot.selection != nil { return .vision }
        return snapshot.isEditable ? .compose : .vision
    }

    /// Adds selection detail to the same Vision destination. Only text the user
    /// actually selected qualifies. A failed read, a timeout, a focused
    /// element, and an `AXSelected` current item are not evidence that the user
    /// chose anything: those summons are ordinary Vision, which is the complete
    /// surface rather than a degraded one.
    static func selectionExtension(for snapshot: AXFocusSnapshot) -> VisionSelectionContext? {
        guard !snapshot.isSecureField else { return nil }
        return snapshot.selection
    }
}

/// The bounded-retry rule is also pure. Waiting is justified only by a positive
/// sign that selection evidence can still appear, never by the mere absence of
/// a selection: the summon blocks on this read, and most summons happen on a
/// screen where the user selected nothing at all.
enum AXFocusSnapshotRetryPolicy {
    static func shouldRetry(
        pass: Int,
        maxPasses: Int,
        beforeExpiry: Bool,
        hasSelection: Bool,
        hasFocusedElement: Bool,
        sawWebArea: Bool,
        hasPartialSelectionEvidence: Bool,
        visitedNodes: Int,
        previousVisitedNodes: Int
    ) -> Bool {
        guard pass < maxPasses, beforeExpiry, !hasSelection else { return false }
        // Focus itself is still missing, so nothing has been observed yet.
        if !hasFocusedElement { return true }
        // The tree is still being built, so more of it is about to exist.
        if Double(visitedNodes) > Double(previousVisitedNodes) * 1.25 { return true }
        // Fragments are visible but the document-wide selection has not settled.
        if hasPartialSelectionEvidence { return true }
        // A web area alone only buys one extra pass for a tree that may still be
        // cold. A settled page with no sign of a selection stops here instead of
        // spending the rest of the budget in front of the user.
        return sawWebArea && pass < 2
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
        // Real windows are far larger than the old 256: Chrome Gmail reports
        // 1,500+ nodes and VS Code 5,800, with their web areas at index 750+.
        // The per-pass deadline, not this number, is what bounds the work.
        static let maxDocumentSearchNodes = 4_000
    }

    /// Secure protection comes from the focused chain: a secure field anywhere
    /// on it aborts the whole snapshot, and a selection lives in one place, so
    /// a non-secure chain means the selected text is not secure either. A
    /// secure field met during this sweep still stops the read. What is no
    /// longer required is a *complete* window sweep — demanding one meant large
    /// apps (Chrome Gmail at 1,500+ nodes, VS Code at 5,800) never read their
    /// document at all, discarding selections that AX had already exposed.
    static func shouldReadDocumentSelection(sawSecureDescendant: Bool) -> Bool {
        !sawSecureDescendant
    }

    /// A web area is the document, wherever it sits on the chain. Chrome makes
    /// it the focused element itself, so scope must come from the role rather
    /// than from the walk position.
    static func selectionScope(
        role: String?,
        isFocusedElement: Bool
    ) -> VisionSelectionCandidate.Scope {
        if role == "AXWebArea" { return .document }
        return isFocusedElement ? .focusedElement : .ancestor
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
                sawWebArea: attempt.sawWebArea
            )
            let retry = AXFocusSnapshotRetryPolicy.shouldRetry(
                pass: pass,
                maxPasses: Budget.maxPasses,
                beforeExpiry: Date() < expiry,
                hasSelection: hasSelection,
                hasFocusedElement: attempt.hasFocusedElement,
                sawWebArea: attempt.sawWebArea,
                hasPartialSelectionEvidence: hasPartialSelectionEvidence(
                    candidates: attempt.selectionCandidates,
                    sawWebArea: attempt.sawWebArea
                ),
                visitedNodes: attempt.visitedNodes,
                previousVisitedNodes: previousVisitedNodes
            )
            previousVisitedNodes = attempt.visitedNodes
            guard retry else { break }
            try? await Task.sleep(nanoseconds: Budget.passWaitNanoseconds)
        }

        return AXFocusSnapshot(
            selection: VisionSelectionResolver.resolve(candidates: selectionCandidates),
            role: best.role,
            label: best.label,
            frame: best.frame,
            isEditable: best.isEditable,
            isSecureField: best.isSecureField,
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
        sawWebArea: Bool
    ) -> Bool {
        if candidates.contains(where: { $0.scope == .document }) { return true }
        return !sawWebArea && !candidates.isEmpty
    }

    /// Fragments are visible but the document-wide selection has not appeared.
    /// This is the only unsettled state where waiting can still change the
    /// answer, so it is the only one that keeps spending the budget.
    static func hasPartialSelectionEvidence(
        candidates: [VisionSelectionCandidate],
        sawWebArea: Bool
    ) -> Bool {
        sawWebArea
            && !candidates.isEmpty
            && !candidates.contains { $0.scope == .document }
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

            // Read every container on this chain, web areas included. Chrome
            // reports the document itself as the focused element, so skipping
            // it here threw the selection away even though AX had returned it.
            // Secure content is already excluded: a secure field anywhere on
            // this chain aborts the whole snapshot above, and a selection lives
            // in one place, so a non-secure chain means non-secure text.
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
                    scope: selectionScope(role: role, isFocusedElement: visited == 1),
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
        // Only sweep the window when the focused chain gave nothing at all.
        // When it did, the document has already been read on that chain and a
        // second full walk would just spend the budget in front of the user.
        if selectionCandidates.isEmpty, Date() < deadline {
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
        var documentElements: [(element: AXUIElement, depth: Int)] = []
        var stack: [AXUIElement] = [window]
        var visited = 0
        var sawWebArea = false
        var sawSecureDescendant = false
        while let element = stack.popLast(),
              visited < Budget.maxDocumentSearchNodes,
              Date() < deadline {
            visited += 1
            let subrole = copyString(element, kAXSubroleAttribute).value
            if subrole == "AXSecureTextField" {
                sawSecureDescendant = true
                continue
            }
            let role = copyString(element, kAXRoleAttribute).value
            if role == "AXWebArea" {
                sawWebArea = true
                documentElements.append((element, startingDepth + visited))
            }
            if let children = copyChildren(element) {
                stack.append(contentsOf: children.reversed())
            }
        }
        var candidates: [VisionSelectionCandidate] = []
        if shouldReadDocumentSelection(sawSecureDescendant: sawSecureDescendant) {
            for document in documentElements where Date() < deadline {
                let selectedTextRead = copyString(document.element, kAXSelectedTextAttribute)
                if let text = normalizedSelectedText(selectedTextRead.value) {
                    let evidence = selectedTextEvidence(document.element, directText: text)
                    candidates.append(VisionSelectionCandidate(
                        directText: text,
                        role: "AXWebArea",
                        label: label(for: document.element),
                        containerFrame: copyFrame(document.element).value,
                        selectionFrames: evidence.frame.map { [$0] } ?? [],
                        scope: .document,
                        depth: document.depth,
                        pass: pass,
                        rangeEvidence: evidence.rangeEvidence,
                        isSecure: false
                    ))
                }
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
