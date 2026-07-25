import Foundation

/// A snapshot of what the user was looking at when the panel was summoned:
/// which app, which window, and the surrounding conversation text. This is the
/// L1 (situational) layer of the context engine — it lets the review infer the
/// recipient, tone, and what is being asked, instead of judging the draft in
/// isolation.
///
/// Lifetime: one panel session, in memory only. Never persisted.
struct SituationalContext {
    let appName: String
    let bundleID: String?
    /// Process id of the source app — the handle for approved AX actions
    /// (press a button, focus a field) back into that app.
    let pid: pid_t
    let windowTitle: String?
    /// Host of the page when the source app is a browser, e.g. "mail.google.com".
    /// Most business tools are web apps, where the bundle id is only ever the
    /// browser's and the window title is whatever the page chose to call itself
    /// — a Workspace Gmail tab is titled "<subject> - <address> - <Org> Mail"
    /// and contains no identifying product name at all. The host is the one
    /// signal that names the product reliably.
    ///
    /// Host only, never the path or query: identifying the product is all this
    /// is for, and the rest of a URL is the user's business.
    let host: String?
    /// Text collected from around the focused field (the conversation thread),
    /// in rough reading order, trimmed to a budget. Nil when nothing readable
    /// was found via Accessibility.
    let conversationExcerpt: String?
    /// True when the app's focused element is an editable, non-secure text
    /// control. The proactive suggestion gates on this: without a field to
    /// write into, a compose summon is likely just a transit to Vision, so no
    /// model call is spent. Secure (password) fields are always false.
    let focusedFieldEditable: Bool
    let capturedAt: Date

    var hasConversation: Bool {
        !(conversationExcerpt ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Product-facing label for the source disclosure. This is deliberately
    /// narrower than skill detection: it only prevents a known web product
    /// from being presented to the user as the container browser.
    var detectedProductName: String? {
        let normalizedHost = host?.lowercased()
        if normalizedHost == "mail.google.com" { return "Gmail" }
        if normalizedHost == "app.slack.com"
            || bundleID?.lowercased() == "com.tinyspeck.slackmacgap" {
            return "Slack"
        }
        return nil
    }

    var detectionSource: String {
        if let host, !host.isEmpty { return host }
        return appName
    }
}
