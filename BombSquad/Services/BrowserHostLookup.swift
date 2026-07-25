import ApplicationServices
import Foundation

/// Reads the host of the page a browser window is showing. Native app windows
/// yield nil.
///
/// This is how a product is identified: business tools mostly run inside a
/// browser, where the bundle id is only ever the browser's and the window title
/// is whatever the page chose to call itself. Both the compose context and the
/// Vision capture need the same answer, so the walk lives here rather than
/// being written twice with two sets of budgets.
///
/// Host only, never the path or query. Naming the product is the entire purpose
/// and the rest of a URL is the user's business.
enum BrowserHostLookup {
    /// Chromium publishes the document URL on an AXWebArea somewhere inside the
    /// window, so a bounded descent is unavoidable. Both budgets exist to stop
    /// a hung or enormous tree from delaying a panel the user is waiting on.
    static let defaultNodeBudget = 200
    static let defaultDeadline: TimeInterval = 1.0

    /// Safari publishes the document on the window itself; Chromium browsers
    /// publish it on the web area inside, so try the window first.
    static func host(
        in window: AXUIElement,
        nodeBudget: Int = defaultNodeBudget,
        deadline: TimeInterval = defaultDeadline
    ) -> String? {
        if let host = copyString(window, "AXDocument").flatMap(hostComponent) {
            return host
        }

        let expiry = Date().addingTimeInterval(deadline)
        var visited = 0
        var stack: [AXUIElement] = [window]
        while let element = stack.popLast() {
            if visited >= nodeBudget || Date() >= expiry { break }
            visited += 1

            if copyString(element, kAXRoleAttribute) == "AXWebArea" {
                if let url = copyURL(element, "AXURL"), let host = hostComponent(url.absoluteString) {
                    return host
                }
                if let host = copyString(element, "AXDocument").flatMap(hostComponent) {
                    return host
                }
            }

            if let children = copyChildren(element) {
                stack.append(contentsOf: children)
            }
        }
        return nil
    }

    /// Host alone, lowercased and without a leading "www.". A non-web scheme
    /// (a native document window exposing AXDocument as file://) yields nil.
    static func hostComponent(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = components.host?.lowercased(),
              !host.isEmpty
        else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst("www.".count)
        }
        return host
    }

    // MARK: - AX helpers

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func copyURL(_ element: AXUIElement, _ attribute: String) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? URL
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
