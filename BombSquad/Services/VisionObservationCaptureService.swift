import AppKit
import ApplicationServices

/// Collects capture-time metadata that cannot be derived from screenshot
/// pixels. The screenshot remains the source of truth; AX only contributes
/// visible, bounded candidates from the app associated with this capture.
/// No AX handles survive the snapshot.
enum VisionObservationCaptureService {
    struct Snapshot {
        let environment: AppEnvironmentSnapshot?
        let axCandidates: [VisionObservation.Candidate]
    }

    private enum Budget {
        static let maxNodes = 2_000
        static let maxCandidates = 250
        static let deadline: TimeInterval = 1.0
        static let axMessagingTimeout: Float = 0.1
    }

    private static let candidateRoles: Set<String> = [
        "AXButton", "AXLink", "AXPopUpButton", "AXCheckBox", "AXRadioButton",
        "AXMenuItem", "AXMenuButton", "AXTab", "AXDisclosureTriangle",
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
        "AXHeading", "AXStaticText", "AXRow", "AXCell",
    ]

    /// Resolves the target synchronously before our panel can alter focus, then
    /// performs the bounded AX work off the main actor alongside OCR/encoding.
    static func captureTask(
        preferredPID: pid_t?,
        attachment: ScreenshotAttachment
    ) -> Task<Snapshot, Never> {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app: NSRunningApplication?
        if let frontmost, frontmost.processIdentifier != ownPID {
            app = frontmost
        } else if let preferredPID, preferredPID != ownPID {
            app = NSRunningApplication(processIdentifier: preferredPID)
        } else {
            app = nil
        }
        guard let app else {
            return Task { Snapshot(environment: nil, axCandidates: []) }
        }

        let pid = app.processIdentifier
        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let bundleID = app.bundleIdentifier
        let includeEnvironment = AppSettings.isContextCaptureEnabled()
        let mayReadAX = AXIsProcessTrusted()

        return Task.detached(priority: .userInitiated) {
            var windowTitle: String?
            var candidates: [VisionObservation.Candidate] = []
            if mayReadAX {
                let appElement = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(appElement, Budget.axMessagingTimeout)
                AXUIElementSetAttributeValue(
                    appElement,
                    "AXManualAccessibility" as CFString,
                    kCFBooleanTrue
                )
                let window = copyElement(appElement, kAXFocusedWindowAttribute)
                windowTitle = window.flatMap { copyString($0, kAXTitleAttribute) }
                if let captureRect = attachment.captureRect,
                   captureRect.width > 0, captureRect.height > 0 {
                    candidates = collectCandidates(
                        from: window ?? appElement,
                        captureRect: captureRect
                    )
                }
            }

            let environment = includeEnvironment ? AppEnvironmentSnapshot(
                appName: appName,
                bundleID: bundleID,
                windowTitle: windowTitle,
                url: nil
            ) : nil
            return Snapshot(environment: environment, axCandidates: candidates)
        }
    }

    private static func collectCandidates(
        from root: AXUIElement,
        captureRect: CGRect
    ) -> [VisionObservation.Candidate] {
        let deadline = Date().addingTimeInterval(Budget.deadline)
        var visited = 0
        var candidates: [VisionObservation.Candidate] = []
        var stack: [(element: AXUIElement, parentLabel: String?)] = [
            (root, nil),
        ]

        while let item = stack.popLast() {
            if visited >= Budget.maxNodes
                || candidates.count >= Budget.maxCandidates
                || Date() >= deadline {
                break
            }
            visited += 1

            let role = copyString(item.element, kAXRoleAttribute) ?? ""
            let subrole = copyString(item.element, kAXSubroleAttribute) ?? ""
            let isSecure = subrole == "AXSecureTextField"
            let elementLabel = isSecure ? nil : label(for: item.element, role: role)
            if candidateRoles.contains(role),
               let elementLabel,
               let frame = copyFrame(item.element),
               let normalizedRect = normalized(frame, within: captureRect) {
                candidates.append(VisionObservation.Candidate(
                    id: "ax:\(visited - 1)",
                    source: "ax",
                    role: normalizedRole(role),
                    label: String(elementLabel.prefix(512)),
                    rect: normalizedRect,
                    parentLabel: item.parentLabel.map { String($0.prefix(512)) },
                    states: states(for: item.element, role: role)
                ))
            }

            let nearestParentLabel = elementLabel ?? item.parentLabel
            if let children = copyChildren(item.element) {
                for child in children.reversed() {
                    stack.append((child, nearestParentLabel))
                }
            }
        }
        return candidates
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
