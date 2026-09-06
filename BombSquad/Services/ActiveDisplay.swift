import AppKit
import ApplicationServices

/// Which screen the user is actually working on.
///
/// This used to be "the screen the pointer is on", and on one display that is
/// the same thing. On two it is not: the pointer routinely sits parked on a
/// second display while the user types on the first. Following it meant
/// screenshotting a screen the user was not looking at and opening the panel
/// over there — an answer about the wrong screen, in the wrong place.
///
/// The reliable signal is the focused window of the app that was frontmost when
/// the user summoned us. Keyboard focus is what "the screen I am working on"
/// means; the pointer is only a fallback for when Accessibility cannot tell us.
///
/// The resolved screen is pinned for the duration of a session so that a panel,
/// its captures, and any mode change afterwards all stay on one display even if
/// the pointer wanders while the panel is up.
@MainActor
enum ActiveDisplay {
    private static var pinnedScreen: NSScreen?

    /// How the working screen was found. Recorded at every pin so a session
    /// that captured the wrong screen can be traced to its cause, instead of
    /// being inferred from a zero further down (`window_off_capture`).
    enum PinSource: String, DiagnosticCode {
        case focusedWindow
        case frontWindow
        case pointer
        case none

        var diagnosticCode: String { rawValue }
    }

    /// Resolve and remember the working screen. Call at summon, before our own
    /// panel activates — once it does, the frontmost app is us.
    @discardableResult
    static func pin(to app: NSRunningApplication?) -> NSScreen? {
        let resolved: NSScreen?
        let via: PinSource
        if let screen = focusedWindowScreen(of: app) {
            resolved = screen
            via = .focusedWindow
        } else if let screen = frontWindowScreen(of: app) {
            resolved = screen
            via = .frontWindow
        } else if let screen = pointerScreen() {
            resolved = screen
            via = .pointer
        } else {
            resolved = nil
            via = .none
        }
        pinnedScreen = resolved
        Diagnostics.record("display.pinned", details: [
            ("via", .code(via)),
            ("display", .count(Int(displayID(of: resolved) ?? 0))),
        ])
        return resolved
    }

    /// Forget the pinned screen; the next summon resolves again.
    static func unpin() {
        pinnedScreen = nil
    }

    /// The working screen: what was pinned at summon, or the pointer's screen
    /// when nothing is pinned.
    static func screen() -> NSScreen? {
        pinnedScreen ?? pointerScreen()
    }

    static func displayID(of screen: NSScreen?) -> CGDirectDisplayID? {
        screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? CGDirectDisplayID
    }

    private static func pointerScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    private static func focusedWindowScreen(of app: NSRunningApplication?) -> NSScreen? {
        guard AXIsProcessTrusted(),
              let pid = app?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        guard let window = copyElement(appElement, kAXFocusedWindowAttribute),
              let origin = copyPoint(window, kAXPositionAttribute),
              let size = copySize(window, kAXSizeAttribute),
              size.width > 0, size.height > 0
        else { return nil }

        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        return screen(containingAXPoint: center)
    }

    /// The app's frontmost on-screen window, asked of the window server rather
    /// than of the app. An Electron app that has not built its accessibility
    /// tree yet answers nothing about its focused window for a while (VS Code,
    /// 2026-09-06: seven nodes, twice), and falling straight through to the
    /// pointer put the whole session — capture, wash, every frame — on the
    /// display the pointer happened to be parked on. The window server knows
    /// where the window is regardless.
    private static func frontWindowScreen(of app: NSRunningApplication?) -> NSScreen? {
        guard let pid = app?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]]
        else { return nil }
        // Front-to-back, so the first layer-0 window of this app is its front one.
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 0, height > 0
            else { continue }
            // Window-server bounds share the accessibility API's top-left space.
            return screen(containingAXPoint: CGPoint(x: x + width / 2, y: y + height / 2))
        }
        return nil
    }

    /// Accessibility reports positions in a top-left origin space anchored to
    /// the primary display; NSScreen speaks bottom-left. Flip once against the
    /// primary screen (always index 0) rather than converting every frame.
    private static func screen(containingAXPoint point: CGPoint) -> NSScreen? {
        guard let primaryTop = NSScreen.screens.first?.frame.maxY else { return nil }
        let flipped = CGPoint(x: point.x, y: primaryTop - point.y)
        return NSScreen.screens.first { $0.frame.contains(flipped) }
    }

    private static func copyElement(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAXValue(element, attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private static func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAXValue(element, attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }

    private static func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }
}
