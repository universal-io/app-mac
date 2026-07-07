import AppKit

/// The window contract of a mode, derived from `AppMode` as a pure function
/// (redesign plan §4-d): size, placement, and whether losing app-active
/// closes the panel. The whole "what shape is the panel in mode X" question
/// reads in this one file.
struct PanelSpec: Equatable {
    enum Placement: Equatable {
        /// Centered on the screen the cursor is on.
        case centered
        /// Bottom-right corner of the cursor's screen (copilot strip).
        case bottomTrailing
    }

    var size: NSSize
    var placement: Placement
    /// Modal panels close when focus moves to another app. The capture
    /// overlay and guided navigation invert the rule: focus living in the
    /// target app IS the normal state there.
    var isModal: Bool

    /// Single Spotlight-style column (compose / transform).
    static let text = PanelSpec(
        size: NSSize(width: 680, height: 660), placement: .centered, isModal: true
    )
    /// Two panes: screenshot + interpretation (navigator).
    static let vision = PanelSpec(
        size: NSSize(width: 960, height: 640), placement: .centered, isModal: true
    )
    /// Corner strip that never covers the screen being navigated (copilot).
    static let copilotStrip = PanelSpec(
        size: NSSize(width: 460, height: 240), placement: .bottomTrailing, isModal: false
    )
}

extension AppMode {
    /// nil = no panel (idle). The capture state keeps the compose shape but
    /// drops modality — the selection overlay owns the screen.
    var panelSpec: PanelSpec? {
        switch self {
        case .idle:
            return nil
        case .compose, .transform:
            return .text
        case .capturing:
            var spec = PanelSpec.text
            spec.isModal = false
            return spec
        case .navigator:
            return .vision
        case .copilot:
            return .copilotStrip
        }
    }
}
