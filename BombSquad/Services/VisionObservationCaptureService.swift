import AppKit
import ApplicationServices

/// The operational trail, reachable from inside this file. `Diagnostics` alone
/// resolves to the collector's own nested payload struct once inside the type,
/// and that shadowing is silent — the wrong one simply fails to have `record`.
private typealias OperationalTrail = Diagnostics

/// Collects capture-time metadata that cannot be derived from screenshot
/// pixels. The screenshot remains the source of truth; AX only contributes
/// visible, bounded candidates from the app associated with this capture.
/// No AX handles survive the snapshot.
enum VisionObservationCaptureService {
    struct Diagnostics {
        let elapsedMs: Int
        let visitedNodes: Int
        let candidateCount: Int
        let truncatedReason: String?
        var targetAppName: String? = nil
        var targetBundleID: String? = nil
        var targetWindowTitle: String? = nil
        var collectionRoot: String = "none"
        var captureScope: String = "unknown"
        var collectionPasses: Int = 0
        var webAreaPresent: Bool = false

        var wirePayload: [String: Any] {
            var payload: [String: Any] = [
                "elapsed_ms": elapsedMs,
                "visited_nodes": visitedNodes,
                "candidate_count": candidateCount,
            ]
            if let truncatedReason { payload["truncated_reason"] = truncatedReason }
            // App identity and window titles are useful only in the local
            // DEBUG UI. Never send them to the Gateway or persist them in
            // usage diagnostics.
            payload["target_window_present"] = targetWindowTitle != nil
            payload["collection_root"] = collectionRoot
            payload["capture_scope"] = captureScope
            payload["collection_passes"] = collectionPasses
            payload["web_area_present"] = webAreaPresent
            return payload
        }
    }

    struct Snapshot {
        let environment: AppEnvironmentSnapshot?
        let axCandidates: [VisionObservation.Candidate]
        let diagnostics: Diagnostics
    }

    /// Which product the user is looking at. Sent with the Vision request so the
    /// Gateway can attach that product's skill; nothing here is persisted, which
    /// is why it is separate from `Diagnostics` (the identity-free struct that
    /// feeds usage). The host is the deciding signal for web products — see
    /// `BrowserHostLookup`.
    struct TargetIdentity: Equatable {
        let appName: String
        let bundleID: String?
        let windowTitle: String?
        let host: String?

        /// The compose path already resolved all of this at summon. Reusing it
        /// costs nothing and is warm, so Vision entered from compose never pays
        /// for a second lookup.
        init(context: SituationalContext) {
            self.appName = context.appName
            self.bundleID = context.bundleID
            self.windowTitle = context.windowTitle
            self.host = context.host
        }

        init(appName: String, bundleID: String?, windowTitle: String?, host: String?) {
            self.appName = appName
            self.bundleID = bundleID
            self.windowTitle = windowTitle
            self.host = host
        }

        var wirePayload: [String: Any] {
            var payload: [String: Any] = ["app_name": String(appName.prefix(256))]
            if let bundleID, !bundleID.isEmpty {
                payload["bundle_id"] = String(bundleID.prefix(256))
            }
            if let windowTitle, !windowTitle.isEmpty {
                payload["window_title"] = String(windowTitle.prefix(1_024))
            }
            if let host, !host.isEmpty {
                payload["host"] = String(host.prefix(256))
            }
            return payload
        }
    }

    private struct CollectionResult {
        let candidates: [VisionObservation.Candidate]
        let visitedNodes: Int
        let truncatedReason: String?
        let sawWebArea: Bool
    }

    private enum Budget {
        static let maxNodes = 2_000
        static let maxCandidates = 500
        static let deadline: TimeInterval = 1.0
        static let axMessagingTimeout: Float = 0.1
        /// Chromium builds its web-content AX tree lazily: only after
        /// AXEnhancedUserInterface is set AND an AX client keeps querying
        /// (measured on Chrome 150: 99 shallow nodes → web area appears
        /// within ~1s of sustained queries, then grows over further passes).
        /// A single 1s pass therefore misses browser content entirely.
        static let maxPasses = 5
        static let totalDeadline: TimeInterval = 5.0
        static let passWaitNanoseconds: UInt64 = 500_000_000
        /// A later pass replaces the previous one when the tree is still
        /// materializing; 25% node growth distinguishes that from jitter.
        static let growthFactor = 1.25
    }

    /// Identity resolution runs alongside the screenshot, so its budget is set
    /// by how long a cold Chromium takes to publish its web area (~1s of
    /// sustained querying), not by what a user would tolerate waiting for.
    private enum IdentityBudget {
        static let maxPasses = 6
        static let totalDeadline: TimeInterval = 2.0
        static let passWaitNanoseconds: UInt64 = 250_000_000
        /// Node growth that distinguishes a tree still materializing from jitter.
        static let growthFactor = 1.25
    }

    private static let candidateRoles: Set<String> = [
        "AXButton", "AXLink", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXMenuItem", "AXMenuButton", "AXTab", "AXDisclosureTriangle",
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// Resolves the target synchronously before our panel can alter focus, then
    /// performs the bounded AX work off the main actor alongside OCR/encoding.
    static func captureTask(
        preferredPID: pid_t?,
        attachment: ScreenshotAttachment
    ) -> Task<Snapshot, Never> {
        guard let app = resolveTargetApp(preferredPID: preferredPID) else {
            return Task {
                Snapshot(
                    environment: nil,
                    axCandidates: [],
                    diagnostics: Diagnostics(
                        elapsedMs: 0,
                        visitedNodes: 0,
                        candidateCount: 0,
                        truncatedReason: "no_target_app",
                        captureScope: attachment.captureScope.rawValue
                    )
                )
            }
        }

        let pid = app.processIdentifier
        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let bundleID = app.bundleIdentifier
        let includeEnvironment = AppSettings.isContextCaptureEnabled()
        let mayReadAX = AXIsProcessTrusted()

        return Task.detached(priority: .userInitiated) {
            let started = Date()
            var windowTitle: String?
            var candidates: [VisionObservation.Candidate] = []
            var visitedNodes = 0
            var truncatedReason: String?
            var collectionRoot = "none"
            var collectionPasses = 0
            var webAreaPresent = false
            if mayReadAX {
                let appElement = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(appElement, Budget.axMessagingTimeout)
                // Electron exposes its web tree after AXManualAccessibility;
                // Chromium browsers ignore that attribute and instead need
                // AXEnhancedUserInterface plus sustained querying (see
                // Budget.maxPasses). Setting both is harmless elsewhere.
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
                let window = copyElement(appElement, kAXFocusedWindowAttribute)
                windowTitle = window.flatMap { copyString($0, kAXTitleAttribute) }
                collectionRoot = window == nil ? "application" : "focused_window"
                if let captureRect = attachment.captureRect,
                   captureRect.width > 0, captureRect.height > 0 {
                    let overallDeadline = started.addingTimeInterval(Budget.totalDeadline)
                    var previousVisited = 0
                    var firstPassCandidates = 0
                    while collectionPasses < Budget.maxPasses {
                        collectionPasses += 1
                        let result = collectCandidates(
                            from: window ?? appElement,
                            captureRect: captureRect
                        )
                        webAreaPresent = webAreaPresent || result.sawWebArea
                        if collectionPasses == 1 {
                            firstPassCandidates = result.candidates.count
                        }
                        if result.candidates.count >= candidates.count {
                            candidates = result.candidates
                            visitedNodes = result.visitedNodes
                            truncatedReason = result.truncatedReason
                        }
#if DEBUG
                        NSLog(
                            "Vision AX collection pass=%d visited=%d candidates=%d webArea=%d reason=%@",
                            collectionPasses, result.visitedNodes, result.candidates.count,
                            result.sawWebArea ? 1 : 0, result.truncatedReason ?? "complete"
                        )
#endif
                        // Retry while the lazily built web tree is still
                        // materializing: no web area yet on the first pass
                        // (cold browser), or the node count is still growing.
                        let coldWebContent = !result.sawWebArea && collectionPasses == 1
                        let stillGrowing = result.sawWebArea
                            && Double(result.visitedNodes)
                                > Double(previousVisited) * Budget.growthFactor
                        previousVisited = result.visitedNodes
                        guard collectionPasses < Budget.maxPasses,
                              Date() < overallDeadline,
                              coldWebContent || stillGrowing else { break }
                        try? await Task.sleep(nanoseconds: Budget.passWaitNanoseconds)
                    }
                    // Every extra pass costs the 500ms wait plus the walk, and
                    // the user waits through all of it before the request can
                    // leave. Whether that buys anything was only observable in
                    // a DEBUG build until now, which is why the one measured
                    // session had to be a DEBUG one: 11 collections, 11 second
                    // passes, 11 identical results (guidance-accuracy-plan 1-k).
                    // `gained` is the number that decides whether the retry
                    // policy can be tightened — from real machines, not one.
                    OperationalTrail.record("vision.axCollected", details: [
                        ("passes", .count(collectionPasses)),
                        ("elapsed", .ms(Int(Date().timeIntervalSince(started) * 1_000))),
                        ("candidates", .count(candidates.count)),
                        ("gained", .count(candidates.count - firstPassCandidates)),
                        ("webArea", .flag(webAreaPresent)),
                        ("truncated", .code(AXTruncationCode(truncatedReason))),
                    ])
                } else {
                    truncatedReason = "unknown_capture_rect"
                }
            } else {
                truncatedReason = "permission_denied"
            }

            let environment = includeEnvironment ? AppEnvironmentSnapshot(
                appName: appName,
                bundleID: bundleID,
                windowTitle: windowTitle,
                url: nil
            ) : nil
            return Snapshot(
                environment: environment,
                axCandidates: candidates,
                diagnostics: Diagnostics(
                    elapsedMs: Int(Date().timeIntervalSince(started) * 1_000),
                    visitedNodes: visitedNodes,
                    candidateCount: candidates.count,
                    truncatedReason: truncatedReason,
                    targetAppName: appName,
                    targetBundleID: bundleID,
                    targetWindowTitle: windowTitle,
                    collectionRoot: collectionRoot,
                    captureScope: attachment.captureScope.rawValue,
                    collectionPasses: collectionPasses,
                    webAreaPresent: webAreaPresent
                )
            )
        }
    }

    /// Resolves which product is on screen. Start this at summon, in parallel
    /// with the screenshot: the first Vision turn is the one the user judges the
    /// app on, and a skill that only arrives on the second turn is a skill that
    /// missed the screen it was written for. Run early it is free, because the
    /// capture it overlaps with takes longer than the lookup.
    ///
    /// Chromium builds its web AX tree only once an AX client asks and keeps
    /// asking, so a single lookup on a cold browser sees a window with no web
    /// area — indistinguishable from a native app. Hence the passes: keep
    /// asking while the tree is visibly still growing, and stop the moment the
    /// host appears or the tree proves to be a native one.
    ///
    /// Returns nil when the user turned screen-context capture off, when
    /// Accessibility is not granted, or when no target app could be resolved.
    /// Vision then runs its fully general path, which is the point of skills
    /// being data: nothing here can break a screen that has no skill.
    static func identityTask(preferredPID: pid_t?) -> Task<TargetIdentity?, Never> {
        guard AppSettings.isContextCaptureEnabled(), AXIsProcessTrusted(),
              let app = resolveTargetApp(preferredPID: preferredPID) else {
            return Task { nil }
        }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let bundleID = app.bundleIdentifier

        return Task.detached(priority: .userInitiated) {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, Budget.axMessagingTimeout)
            // Same lazily built trees the candidate collection deals with:
            // Electron needs AXManualAccessibility, Chromium AXEnhancedUserInterface.
            // Asking here starts the tree materializing at the earliest moment
            // instead of waiting for the first candidate pass.
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
            var window = copyElement(appElement, kAXFocusedWindowAttribute)
            var host: String?
            var previousNodes = 0
            var pass = 0
            let expiry = Date().addingTimeInterval(IdentityBudget.totalDeadline)
            while pass < IdentityBudget.maxPasses {
                pass += 1
                guard let target = window else { break }
                let probe = BrowserHostLookup.probe(in: target)
                if let found = probe.host {
                    host = found
                    break
                }
                // A window with no web area and a tree that stopped growing is
                // a native window: nothing will appear by asking again.
                let stillGrowing = Double(probe.visitedNodes)
                    > Double(previousNodes) * IdentityBudget.growthFactor
                previousNodes = probe.visitedNodes
                guard probe.sawWebArea || stillGrowing,
                      pass < IdentityBudget.maxPasses,
                      Date() < expiry else { break }
                try? await Task.sleep(nanoseconds: IdentityBudget.passWaitNanoseconds)
                window = copyElement(appElement, kAXFocusedWindowAttribute) ?? window
            }
            return TargetIdentity(
                appName: appName,
                bundleID: bundleID,
                windowTitle: window.flatMap { copyString($0, kAXTitleAttribute) },
                host: host
            )
        }
    }

    /// Resolution order, most to least reliable for "the app the user is
    /// looking at": the live frontmost app; the frontmost on-screen real
    /// window's owner (catches the moment our own panel/overlay holds focus —
    /// the previous cause of intermittent no_target_app); and finally the
    /// summon-time PID, which is two gestures stale.
    private static func resolveTargetApp(preferredPID: pid_t?) -> NSRunningApplication? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID {
            return frontmost
        }
        if let onScreen = frontmostRegularApp(excluding: ownPID) {
            return onScreen
        }
        if let preferredPID, preferredPID != ownPID {
            return NSRunningApplication(processIdentifier: preferredPID)
        }
        return nil
    }

    /// The owner of the frontmost real on-screen window that is not us.
    /// CGWindowList returns windows front-to-back, so the first layer-0
    /// window belonging to a regular app other than ourselves is the app
    /// the user is actually looking at — independent of who currently holds
    /// keyboard focus (our panel may).
    private static func frontmostRegularApp(excluding ownPID: pid_t) -> NSRunningApplication? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for window in windows {
            guard
                let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                let app = NSRunningApplication(processIdentifier: pid),
                app.activationPolicy == .regular
            else { continue }
            return app
        }
        return nil
    }

    private static func collectCandidates(
        from root: AXUIElement,
        captureRect: CGRect
    ) -> CollectionResult {
        let deadline = Date().addingTimeInterval(Budget.deadline)
        var visited = 0
        var candidates: [VisionObservation.Candidate] = []
        var stack: [(element: AXUIElement, parentLabel: String?, unlabeledActionRole: String?)] = [
            (root, nil, nil),
        ]

        var truncatedReason: String?
        var sawWebArea = false

        while !stack.isEmpty {
            if visited >= Budget.maxNodes {
                truncatedReason = "node_limit"
                break
            }
            if candidates.count >= Budget.maxCandidates {
                truncatedReason = "candidate_limit"
                break
            }
            if Date() >= deadline {
                truncatedReason = "deadline"
                break
            }
            let item = stack.removeLast()
            visited += 1

            let role = copyString(item.element, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" { sawWebArea = true }
            let subrole = copyString(item.element, kAXSubroleAttribute) ?? ""
            let isSecure = subrole == "AXSecureTextField"
            let elementLabel = isSecure ? nil : label(for: item.element, role: role)
            let directActionRole = candidateRoles.contains(role) ? role : nil
            let inheritedActionRole = role == "AXStaticText" ? item.unlabeledActionRole : nil
            if let candidateRole = directActionRole ?? inheritedActionRole,
               let elementLabel,
               let frame = copyFrame(item.element),
               let normalizedRect = normalized(frame, within: captureRect) {
                candidates.append(VisionObservation.Candidate(
                    id: "ax:\(visited - 1)",
                    source: "ax",
                    role: normalizedRole(candidateRole),
                    label: String(elementLabel.prefix(512)),
                    rect: normalizedRect,
                    parentLabel: item.parentLabel.map { String($0.prefix(512)) },
                    states: states(for: item.element, role: role)
                ))
            }

            let nearestParentLabel = elementLabel ?? item.parentLabel
            let nearestUnlabeledActionRole: String?
            if let directActionRole {
                nearestUnlabeledActionRole = elementLabel == nil ? directActionRole : nil
            } else {
                nearestUnlabeledActionRole = item.unlabeledActionRole
            }
            if let children = copyChildren(item.element) {
                for child in children.reversed() {
                    stack.append((child, nearestParentLabel, nearestUnlabeledActionRole))
                }
            }
        }
        return CollectionResult(
            candidates: candidates,
            visitedNodes: visited,
            truncatedReason: truncatedReason,
            sawWebArea: sawWebArea
        )
    }

    private static func label(for element: AXUIElement, role: String) -> String? {
        var values = [
            copyString(element, kAXTitleAttribute),
            copyString(element, kAXDescriptionAttribute),
            copyString(element, "AXLabel"),
            copyString(element, "AXPlaceholderValue"),
        ]
        if role == "AXStaticText" || role == "AXHeading" {
            values.append(copyString(element, kAXValueAttribute))
        }
        return values.compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.first { !$0.isEmpty }
    }

    private static func states(for element: AXUIElement, role: String) -> [String] {
        var result: [String] = []
        if copyBool(element, kAXEnabledAttribute) == false { result.append("disabled") }
        if copyBool(element, kAXFocusedAttribute) == true { result.append("focused") }
        if copyBool(element, kAXSelectedAttribute) == true { result.append("selected") }
        if let expanded = copyBool(element, "AXExpanded") {
            result.append(expanded ? "expanded" : "collapsed")
        }
        if role == "AXCheckBox" || role == "AXRadioButton" {
            if let selected = copyBool(element, kAXValueAttribute) {
                result.append(selected ? "checked" : "unchecked")
            }
        }
        return result
    }

    private static func normalized(_ frame: CGRect, within captureRect: CGRect) -> CGRect? {
        let visible = frame.intersection(captureRect)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return CGRect(
            x: (visible.minX - captureRect.minX) / captureRect.width,
            y: (visible.minY - captureRect.minY) / captureRect.height,
            width: visible.width / captureRect.width,
            height: visible.height / captureRect.height
        )
    }

    private static func normalizedRole(_ role: String) -> String {
        let value = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        return value.lowercased()
    }

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

    private static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value
        else { return nil }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
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
