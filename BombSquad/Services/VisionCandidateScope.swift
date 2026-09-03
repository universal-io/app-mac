import Foundation

/// Which measured elements belong to the tool the user is looking at, and which
/// measured state is worth stating at all.
///
/// Kept apart from the accessibility calls on purpose. The questions here are
/// about the product, not about macOS, so Windows can reuse these answers with a
/// different API underneath (docs: Windows inherits the Mac reasoning, not the
/// Mac calls). It also makes them testable: the walk needs a live tree, these
/// need nothing.
enum VisionCandidateScope {

    // MARK: - What counts as the tool on screen

    /// Whether a measured element outside the page should be offered to the
    /// model, given that the walk found a web area somewhere in the window.
    ///
    /// A browser window is two tools stacked: the product the user came for, and
    /// the browser holding it. Measured on GA4 (2026-09-03, 26 screens), the
    /// browser half was **57 of roughly 122 candidates on every single screen** —
    /// bookmarks, the tab strip, extensions, the address bar. Three costs, all
    /// paid on every turn:
    ///
    /// 1. About 3,700 tokens of a prompt that is already large.
    /// 2. Other people's business. A bookmark's label *is* its URL and a tab's
    ///    label is its page title, so the request carried other sites' addresses
    ///    and an email address — while deliberately withholding the address of
    ///    the page actually being explained.
    /// 3. A false signal. On those 26 screens nothing in the page ever carried
    ///    `selected`, and the browser's current tab always did, so the one
    ///    element claiming to be "the selected one" was never part of the tool.
    ///
    /// The rule is structural rather than a list of browser labels, which is why
    /// it survives other browsers and other languages. Measured the same day on
    /// the apps that were running: Slack 95 candidates and VS Code 197, **all of
    /// them inside the web area** (Electron is web content all the way out to its
    /// window edge, so nothing is lost); Finder and Xcode expose no web area at
    /// all, so they keep every candidate.
    ///
    /// What this gives up: nothing in the browser's own furniture can be pointed
    /// at — back, reload, a tab, the address bar. Guidance already refuses to
    /// send people backwards, and it navigates products rather than browsers, so
    /// the loss is real but not in the path of the work.
    static func keepsChrome(sawWebArea: Bool) -> Bool { !sawWebArea }

    /// Applies `keepsChrome` to one walk's findings.
    ///
    /// The decision cannot be made while walking: a window's chrome is reached
    /// before the page inside it, so whether a web area exists is only known once
    /// the walk ends. Everything is collected, then filtered.
    static func inTool<Element>(
        _ found: [(element: Element, insideWebArea: Bool)],
        sawWebArea: Bool
    ) -> [Element] {
        guard !keepsChrome(sawWebArea: sawWebArea) else { return found.map(\.element) }
        return found.filter(\.insideWebArea).map(\.element)
    }

    // MARK: - Which states say something

    /// Controls where being closed is the whole point, so saying so is a fact
    /// about the screen rather than an artefact of the toolkit.
    static let expansionBearingRoles: Set<String> = ["AXDisclosureTriangle"]

    /// The expansion state to report, or nil to say nothing.
    ///
    /// `AXExpanded` is answered by nearly every web element and the answer is
    /// nearly always false. Measured on the same 26 GA4 screens: **1,665 of 1,688
    /// page candidates carried `collapsed`**, text fields included, and only 23
    /// carried `expanded`. Slack and VS Code report the same shape (93 of 95 and
    /// 194 of 197 false), while Finder and Xcode answer the attribute for no
    /// candidate at all.
    ///
    /// A word every element says is not evidence, and this one actively misleads:
    /// an *open* GA4 section is labelled `collapsed` exactly like a closed one,
    /// so acting on it tells the user to open what is already open, which closes
    /// it. So `expanded` is reported when it is true — that much was always
    /// earned — and `collapsed` only where a closed control is the thing the user
    /// is being asked to notice.
    static func expansionState(role: String, isExpanded: Bool) -> String? {
        if isExpanded { return "expanded" }
        return expansionBearingRoles.contains(role) ? "collapsed" : nil
    }
}
