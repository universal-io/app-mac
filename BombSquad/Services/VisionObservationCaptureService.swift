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
        /// Measured elements dropped for sitting outside the page (browser
        /// furniture). Recorded so the filter stays visible in the trail rather
        /// than silently shrinking the evidence.
        let chromeDropped: Int
    }

    private enum Budget {
        /// Sized to hold a real tree rather than to bound cost — the deadline
        /// below does that, and it is the only bound the user feels.
        ///
        /// 2,000 was calibrated when each node cost seven cross-process reads.
        /// Batching them (`nodeFacts`) made a node 3-6x cheaper, at which point
        /// the old cap stopped protecting anything and started being the reason
        /// candidates went missing: VS Code's 3,300-node tree was cut at 61%,
        /// and an earlier 6,885-node one at 29%. Measured trees on 2026-08-05 —
        /// VS Code 3,300-6,900, Chrome 1,700, Xcode 800, Slack 450, Finder 270 —
        /// all fit under 8,000, and 8,000 batched browser nodes cost about
        /// 800ms, so the deadline still decides (docs/latency-plan.md 1-h).
        static let maxNodes = 8_000
        static let maxCandidates = 500
        /// The user-visible ceiling on one pass. Deliberately unchanged: the
        /// same second now buys several times more of the tree, so coverage
        /// improves without anyone waiting longer.
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
                    var chromeDropped = 0
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
                            chromeDropped = result.chromeDropped
                        }
#if DEBUG
                        NSLog(
                            "Vision AX collection pass=%d visited=%d candidates=%d chrome=%d webArea=%d reason=%@",
                            collectionPasses, result.visitedNodes, result.candidates.count,
                            result.chromeDropped, result.sawWebArea ? 1 : 0,
                            result.truncatedReason ?? "complete"
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
                        // Measured elements left out for belonging to the browser
                        // rather than the page. Recorded so a filter that starts
                        // removing too much is visible, not inferred.
                        ("chrome", .count(chromeDropped)),
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
        var found: [(element: VisionObservation.Candidate, insideWebArea: Bool)] = []
        var stack: [
            (
                element: AXUIElement,
                parentLabel: String?,
                unlabeledActionRole: String?,
                insideWebArea: Bool
            )
        ] = [
            (root, nil, nil, false),
        ]

        var truncatedReason: String?
        var sawWebArea = false

        while !stack.isEmpty {
            if visited >= Budget.maxNodes {
                truncatedReason = "node_limit"
                break
            }
            if found.count >= Budget.maxCandidates {
                truncatedReason = "candidate_limit"
                break
            }
            if Date() >= deadline {
                truncatedReason = "deadline"
                break
            }
            let item = stack.removeLast()
            visited += 1

            let node = nodeFacts(item.element)
            let role = node.role
            let insideWebArea = item.insideWebArea || role == "AXWebArea"
            if role == "AXWebArea" { sawWebArea = true }
            let isSecure = node.subrole == "AXSecureTextField"
            let elementLabel = isSecure ? nil : node.label
            let directActionRole = candidateRoles.contains(role) ? role : nil
            let inheritedActionRole = role == "AXStaticText" ? item.unlabeledActionRole : nil
            if let candidateRole = directActionRole ?? inheritedActionRole,
               let elementLabel,
               let frame = node.frame,
               let normalizedRect = normalized(frame, within: captureRect) {
                found.append((
                    element: VisionObservation.Candidate(
                        id: "ax:\(visited - 1)",
                        source: "ax",
                        role: normalizedRole(candidateRole),
                        label: String(elementLabel.prefix(512)),
                        rect: normalizedRect,
                        parentLabel: item.parentLabel.map { String($0.prefix(512)) },
                        states: states(for: item.element, role: role)
                    ),
                    insideWebArea: insideWebArea
                ))
            }

            let nearestParentLabel = elementLabel ?? item.parentLabel
            let nearestUnlabeledActionRole: String?
            if let directActionRole {
                nearestUnlabeledActionRole = elementLabel == nil ? directActionRole : nil
            } else {
                nearestUnlabeledActionRole = item.unlabeledActionRole
            }
            for child in node.children.reversed() {
                stack.append((child, nearestParentLabel, nearestUnlabeledActionRole, insideWebArea))
            }
        }
        // The browser's own furniture is a different tool from the one on the
        // page; VisionCandidateScope carries the reasoning and the measurements.
        let candidates = VisionCandidateScope.inTool(found, sawWebArea: sawWebArea)
        return CollectionResult(
            candidates: candidates,
            visitedNodes: visited,
            truncatedReason: truncatedReason,
            sawWebArea: sawWebArea,
            chromeDropped: found.count - candidates.count
        )
    }

    /// Everything the walk needs from one node.
    private struct NodeFacts {
        var role = ""
        var subrole = ""
        var label: String?
        var frame: CGRect?
        var children: [AXUIElement] = []
    }

    /// Attributes fetched together, in the order `nodeFacts` reads them back.
    private static let nodeAttributes: [String] = [
        kAXRoleAttribute,
        kAXSubroleAttribute,
        kAXTitleAttribute,
        kAXDescriptionAttribute,
        "AXLabel",
        "AXPlaceholderValue",
        kAXValueAttribute,
        kAXPositionAttribute,
        kAXSizeAttribute,
        kAXChildrenAttribute,
    ]

    /// One cross-process round trip per node instead of seven.
    ///
    /// Reading attributes one at a time is what made the walk expensive enough
    /// to need a budget, and the budget is what drops the buttons a guide wants
    /// to point at. Measured on 2026-08-05 over three apps: identical
    /// candidates, 2.3x faster on Chrome, 6.5x on Slack, and VS Code's whole
    /// 6,885-node tree in 1,419ms where the old cost reached 29% of it in the
    /// same second (docs/latency-plan.md 1-h).
    ///
    /// The frame now comes back for every node rather than only for candidates.
    /// It rides along in a trip already being made, so asking for it costs
    /// nothing and it is what lets truncation be reasoned about at all.
    private static func nodeFacts(_ element: AXUIElement) -> NodeFacts {
        var facts = NodeFacts()
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            nodeAttributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &raw
        ) == .success,
            let values = raw as? [AnyObject],
            values.count == nodeAttributes.count
        else { return facts }

        // An attribute the element does not support comes back as a wrapped
        // error rather than a string, so the cast fails exactly where the
        // individual read would have failed.
        func text(_ index: Int) -> String? {
            (values[index] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        facts.role = text(0) ?? ""
        facts.subrole = text(1) ?? ""
        var labels = [text(2), text(3), text(4), text(5)]
        if facts.role == "AXStaticText" || facts.role == "AXHeading" {
            labels.append(text(6))
        }
        facts.label = labels.compactMap { $0 }.first { !$0.isEmpty }

        var position = CGPoint.zero
        var size = CGSize.zero
        if CFGetTypeID(values[7]) == AXValueGetTypeID(),
           CFGetTypeID(values[8]) == AXValueGetTypeID(),
           AXValueGetValue((values[7] as! AXValue), .cgPoint, &position),
           AXValueGetValue((values[8] as! AXValue), .cgSize, &size) {
            facts.frame = CGRect(origin: position, size: size)
        }
        if let children = values[9] as? [AnyObject] {
            facts.children = children.compactMap { child in
                guard CFGetTypeID(child) == AXUIElementGetTypeID() else { return nil }
                return (child as! AXUIElement)
            }
        }
        return facts
    }

    private static func states(for element: AXUIElement, role: String) -> [String] {
        var result: [String] = []
        if copyBool(element, kAXEnabledAttribute) == false { result.append("disabled") }
        if copyBool(element, kAXFocusedAttribute) == true { result.append("focused") }
        if copyBool(element, kAXSelectedAttribute) == true { result.append("selected") }
        if let expanded = copyBool(element, "AXExpanded"),
           let state = VisionCandidateScope.expansionState(role: role, isExpanded: expanded) {
            result.append(state)
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

}
