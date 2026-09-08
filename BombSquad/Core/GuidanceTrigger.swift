import Foundation

/// When guidance asks the model again, and when it does not.
///
/// Guidance had one trigger — any click — evaluated one step at a time, with
/// clicks during an evaluation dropped. Measured on a real form (GA4,
/// 2026-09-03): seven of ten steps had a click dropped that way, six of them
/// *after* the capture the step was judging had already been taken. The
/// instruction that came back described a screen the user had left, and its
/// frame landed where a button used to be. Filling a form produced a step per
/// field, each repeating the previous instruction.
///
/// The owner's premise for the redesign: a screenshot is the expensive way to
/// learn what the user did. Clicks, keys, scrolls and the accessibility tree say
/// most of it for free, so the screen is read only when those say the user has
/// moved on. What they mean for the loop is decided here; the monitors and the
/// accessibility reads that feed these rules stay in `VisionSession`, so a
/// Windows port keeps the reasoning and swaps the plumbing.
enum GuidanceTrigger {

    // MARK: - A click

    enum ClickKind: Equatable {
        /// The user acted. Re-plan from the screen once it settles.
        case advance
        /// The user entered a text input. The operation is not done until typing
        /// pauses or focus leaves, so the re-plan waits for that instead of
        /// firing on the click — which is what made a five-field form cost a
        /// step per field, each restating the last instruction.
        case `defer`
    }

    /// Roles a click lands in to type rather than to act. A combo box is here
    /// because a searchable picker is typed into before anything is chosen.
    static let typingRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
    ]

    /// Decided from the element that holds keyboard focus after the click,
    /// which the accessibility tree reports in well under a millisecond
    /// (measured 0.16 ms, Chrome, 2026-09-03). Focus is the truth about what a
    /// click did; the geometry of where it landed is only a guess at it.
    static func clickKind(focusedRole: String?) -> ClickKind {
        guard let focusedRole, typingRoles.contains(focusedRole) else { return .advance }
        return .defer
    }

    /// How long the hand has to pause in a text input before the screen is
    /// read. Long enough not to fire between keystrokes; short enough that a
    /// dropdown opened by typing gets its frame while the user is still looking
    /// at it.
    static let typingIdle: TimeInterval = 0.8

    /// What a deferred act hears while it waits.
    enum DeferredEvent: Equatable {
        /// The click that put focus in the input.
        case enteredInput
        /// A key went down somewhere. Only *that* it did.
        case keyDown
    }

    /// Whether the event starts, or pushes back, the typing-idle clock.
    ///
    /// The click that entered the input starts nothing. The first version
    /// started the clock on that click, so an input that was entered and never
    /// typed into still cost a step 0.8 s later — and in an editor every click
    /// is such a click: on VS Code (2026-09-06) each caret placement bought a
    /// capture with no character typed. So the first key starts the clock and
    /// every key after it pushes the clock back. A form still costs a step per
    /// field *filled*, which is what the deferral was for; a field entered and
    /// left untouched is not an act.
    static func restartsTypingIdle(_ event: DeferredEvent) -> Bool {
        event == .keyDown
    }

    /// How long after the last scroll tick the page counts as settled. Only
    /// consulted when the instruction had nothing to point at — scrolling is how
    /// a user finds the thing a verbal instruction named.
    static let scrollIdle: TimeInterval = 0.6

    // MARK: - An act while a step is running

    /// Where a folded act went. An enum rather than free text so the trail keeps
    /// recording codes, never sentences.
    enum FoldTarget: Equatable {
        case runningStep
        case openQuestion
    }

    enum Disposition: Equatable {
        /// Nothing is running: start a step.
        case start
        /// What the user did will be in what is already coming — the running
        /// step has not taken its capture yet, or a typed question is open.
        /// Recorded, then dropped.
        case fold(into: FoldTarget)
        /// The running step is judging a screen the user has already left. Its
        /// instruction would be about a screen that is gone, so it is cancelled
        /// and a step starts from the screen as it is now.
        case supersede
    }

    /// The old rule was "fold whenever a step is running", on the premise that
    /// the step's capture would include the act. That premise holds only before
    /// the capture; most of a step is spent after it, in the accessibility walk
    /// and the model call.
    static func disposition(
        stepRunning: Bool,
        stepCaptured: Bool,
        questionOpen: Bool
    ) -> Disposition {
        if questionOpen { return .fold(into: .openQuestion) }
        guard stepRunning else { return .start }
        return stepCaptured ? .supersede : .fold(into: .runningStep)
    }
}
