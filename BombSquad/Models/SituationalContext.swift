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

    /// Short label for the panel chip, e.g. "Slack — #general".
    var chipLabel: String {
        if let windowTitle, !windowTitle.isEmpty {
            return "\(appName) — \(windowTitle)"
        }
        return appName
    }
}
