import AppKit

/// R18 V3: guidance by voice. Once the companion has given a step, the next
/// one is read when the user has taken it, without their having to ask.
///
/// This is Vision's copilot loop with the bubble taken out, and none of its
/// rules are new. What counts as acting, how long to wait before reading, and
/// what becomes of an act that lands while a step is being read are
/// `GuidanceTrigger`'s, measured on GA4 and VS Code. When the screen has
/// settled is `StableScreenCaptureService`'s, judged against the picture the
/// last instruction was about (`CompanionEye.latestCapture`). The read is the
/// eye's, so a step marks the screen exactly as a look the model asked for.
///
/// The user's actions are watched with global event monitors only, which take
/// no focus and need no window. A key press is a timestamp here and nothing
/// else; nothing typed is read.
@MainActor
final class CompanionGuide {
    /// Why guidance ended, for the trail.
    enum Ending: String, DiagnosticCode {
        case done
        case stepLimit
        case stopped

        var diagnosticCode: String { rawValue }
    }

    /// Delivered on the main actor when the user acted, the screen settled and the next step was read.
    ///
    /// A step that could not be read arrives as `.failure`, so the session
    /// can decide whether to say so. A step that was withdrawn — superseded by
    /// a newer act, overtaken by a look the model asked for, or stopped — does
    /// not arrive at all. When a step ends guidance (`.done`, or the step
    /// limit), `isActive` is already false by the time it arrives.
    var onStep: ((CompanionEye.Look) -> Void)?
    /// True while a step is being read, false when it is over: an automatic,
    /// billed read is shown in the window, never silent (requirements R17).
    var onReading: ((Bool) -> Void)?
    private(set) var isActive = false

    /// Vision's stop valve (`VisionSession.maxGuideSteps`). The loop has no
    /// halt of its own that does not depend on the model, and every step is a
    /// capture and a billed request.
    nonisolated static let maxSteps = 15
    /// After a click on a control, as Vision waits (`VisionSession.actOnClick`):
    /// the press has to take effect before the screen is watched for it.
    private static let clickSettle: Duration = .milliseconds(700)

    private let eye: CompanionEye
    private var goal = ""
    private var previousInstruction = ""
    private var history: () -> [CompanionEye.Line] = { [] }
    private var displayID: CGDirectDisplayID?
    private var excludedFrame: () -> NSRect? = { nil }
    /// Steps read since `begin`, failures not counted (Vision counts guide
    /// and clarification answers, not errors).
    private var steps = 0

    private var clickMonitor: Any?
    /// Two more things guidance listens for, with the click and for the same
    /// time. Their rules are `GuidanceTrigger`'s.
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var idleTimer: Timer?
    /// A click landed in a text input: the step waits for the hand to pause
    /// (`GuidanceTrigger.ClickKind.defer`).
    private var actDeferred = false

    private var stepTask: Task<Void, Never>?
    /// Which run owns the step state; a superseded run must not reset what its
    /// successor is using.
    private var stepGeneration = 0
    /// Whether the running step has its picture. An act before it is in that
    /// picture; an act after it is one the step cannot see.
    private var stepCaptured = false
    /// Whether the running step's own look is in flight, so that a look the
    /// model asked for can be told apart from it.
    private var stepReading = false

    /// The guide reads through the session's eye, so its marks, its baseline
    /// and the rule that only the newest look is current are shared with the
    /// looks the model asks for.
    init(eye: CompanionEye) {
        self.eye = eye
    }

    // MARK: - Lifecycle

    /// Starts watching the user's actions toward `goal`, after `previousInstruction` was given.
    /// `excludedFrame` returns the companion window's frame (clicks on it are not actions).
    ///
    /// Called while guiding, it is a new goal: the count starts over and a step
    /// being read for the old one is dropped.
    func begin(
        goal: String,
        previousInstruction: String,
        history: @escaping () -> [CompanionEye.Line],
        displayID: CGDirectDisplayID?,
        excludedFrame: @escaping () -> NSRect?
    ) {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = previousInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        // A step is judged against both, and the Gateway refuses guidance
        // without either (route.ts `input.guidance`): there would be nothing
        // to watch for.
        guard !goal.isEmpty, !instruction.isEmpty else { return }
        let restarted = isActive
        cancelStep()
        self.goal = goal
        self.previousInstruction = instruction
        self.history = history
        self.displayID = displayID
        self.excludedFrame = excludedFrame
        steps = 0
        isActive = true
        // The look that gave this step is the newest: its picture is the
        // screen the user is to act on, whatever looks come in between.
        eye.pinGuideCapture()
        installMonitors()
        Diagnostics.record("companion.guideBegan", details: [("restarted", .flag(restarted))])
    }

    /// A new step was spoken (keeps previousInstruction current), e.g. after a look the model asked for.
    ///
    /// Nothing running is cancelled. A step already being read is about the
    /// user's latest act; if a look began after it, the eye reports the step
    /// superseded and it is dropped there.
    func update(previousInstruction: String) {
        let instruction = previousInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isActive, !instruction.isEmpty else { return }
        self.previousInstruction = instruction
    }

    func stop() {
        guard isActive else { return }
        end(.stopped)
    }

    /// The model is looking for itself: the step being read now would say
    /// the same thing as its answer, or an older thing. Guidance itself — the
    /// goal, the count, the watching — carries on.
    /// True when a step was being read and is dropped.
    @discardableResult
    func cancelRunningStep() -> Bool {
        guard isActive, stepTask != nil else { return false }
        cancelStep()
        Diagnostics.record("companion.guideAct", details: [("act", .literal("yielded"))])
        return true
    }

    /// The user acted, but the step read for it was dropped (a look the model
    /// asked for overtook it, and answered something else): read it again now,
    /// on a screen that has already settled.
    func readNow() {
        guard isActive, stepTask == nil else { return }
        Diagnostics.record("companion.guideAct", details: [("act", .literal("reread"))])
        startStep(after: .zero, waitForChange: false)
    }

    /// Whether this step ends guidance: the goal was reached, or the valve
    /// closed.
    nonisolated static func ending(after kind: CompanionEye.Look.Kind, steps: Int) -> Ending? {
        if kind == .done { return .done }
        return steps >= maxSteps ? .stepLimit : nil
    }

    private func end(_ ending: Ending) {
        isActive = false
        cancelStep()
        removeMonitors()
        Diagnostics.record("companion.guideEnded", details: [
            ("via", .code(ending)),
            ("steps", .count(steps)),
        ])
    }

    private func cancelStep() {
        let wasReading = stepTask != nil
        stepGeneration += 1
        stepTask?.cancel()
        stepTask = nil
        stepCaptured = false
        stepReading = false
        if wasReading { onReading?(false) }
    }

    // MARK: - The user's actions

    private func installMonitors() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            // Where the pointer is now, before the hop to the main actor: by
            // the time the task runs the hand has moved on.
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, self.isUserScreen(location) else { return }
                self.actOnClick()
            }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.noteDeferredEvent(.keyDown) }
        }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            // Same read, same reason as the click. A scroll over the
            // companion's window moves its transcript, not the page.
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, self.isUserScreen(location) else { return }
                self.noteScroll()
            }
        }
    }

    private func removeMonitors() {
        for monitor in [clickMonitor, keyMonitor, scrollMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        clickMonitor = nil
        keyMonitor = nil
        scrollMonitor = nil
        idleTimer?.invalidate()
        idleTimer = nil
        actDeferred = false
    }

    /// Everything outside the companion's window is the screen the user was
    /// asked to act on. A click on mute or close reaches a global monitor like
    /// any other while the user's app is in front (`VisionSession.advancesGuidance`).
    private func isUserScreen(_ location: NSPoint) -> Bool {
        guard isActive, VisionSession.advancesGuidance(clickAt: location, bubble: excludedFrame()) else {
            return false
        }
        // A click on another display is not the step: the guide reads the
        // display the instruction was about, which that click did not touch.
        let point = VisionPointerResolver.globalCGPoint(
            cocoaGlobal: location,
            mainDisplayHeight: VisionPointerResolver.mainDisplayHeight
        )
        let guided = eye.guideCapture?.captureRect ?? CGDisplayBounds(displayID ?? CGMainDisplayID())
        return guided.contains(point)
    }

    /// Focus is read right after the click: into a text input, the act is not
    /// done yet and the step waits for the hand to pause; anywhere else, the
    /// user acted.
    private func actOnClick() {
        switch GuidanceTrigger.clickKind(focusedRole: focusedRole()) {
        case .defer:
            actDeferred = true
            Diagnostics.record("companion.guideAct", details: [("act", .literal("deferred"))])
            noteDeferredEvent(.enteredInput)
        case .advance:
            idleTimer?.invalidate()
            idleTimer = nil
            actDeferred = false
            startStep(after: Self.clickSettle, waitForChange: true)
        }
    }

    private func noteDeferredEvent(_ event: GuidanceTrigger.DeferredEvent) {
        guard isActive, actDeferred, GuidanceTrigger.restartsTypingIdle(event) else { return }
        restartIdleTimer(after: GuidanceTrigger.typingIdle, reason: "typingIdle")
    }

    /// A measured mark is kept on its element by the eye itself. The screen
    /// is read again only when the instruction had nothing marked, because
    /// scrolling is how a user finds the thing a spoken instruction named.
    private func noteScroll() {
        guard isActive, !eye.isMarking, stepTask == nil else { return }
        restartIdleTimer(after: GuidanceTrigger.scrollIdle, reason: "scrollIdle")
    }

    private func restartIdleTimer(after interval: TimeInterval, reason: StaticString) {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.idleTimer = nil
                self.actDeferred = false
                Diagnostics.record("companion.guideAct", details: [
                    ("act", .literal("resumed")),
                    ("into", .literal(reason)),
                ])
                // The screen changed while the hand was busy; waiting for a
                // further change now would wait for nothing.
                self.startStep(after: .zero, waitForChange: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    /// The role of whatever holds keyboard focus in the app being guided —
    /// the frontmost one, which is never this app.
    private func focusedRole() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return VisionObservationCaptureService.focusedElementRole(inApplication: app.processIdentifier)
    }

    // MARK: - A step

    private func startStep(after delay: Duration, waitForChange: Bool) {
        guard isActive else { return }
        switch GuidanceTrigger.disposition(
            stepRunning: stepTask != nil,
            stepCaptured: stepCaptured,
            questionOpen: eye.looksInFlight > (stepReading ? 1 : 0)
        ) {
        case .start:
            break
        case .fold(let into):
            // What the user did will be in what is already coming. Recorded,
            // then dropped: a dropped act with no trace looks like an ignored
            // click.
            switch into {
            case .runningStep:
                Diagnostics.record("companion.guideAct", details: [
                    ("act", .literal("folded")), ("into", .literal("runningStep")),
                ])
            case .openQuestion:
                Diagnostics.record("companion.guideAct", details: [
                    ("act", .literal("folded")), ("into", .literal("openQuestion")),
                ])
            }
            return
        case .supersede:
            // The running step is judging a screen the user has already left.
            Diagnostics.record("companion.guideAct", details: [("act", .literal("superseded"))])
        }
        cancelStep()
        let generation = stepGeneration
        // The mark comes off the control the user just pressed: the screen is
        // about to change, and a frame on the old control would be a claim
        // about a screen that no longer exists.
        eye.clearMarks()
        let actAt = Date()
        let baseline = eye.guideCapture
        onReading?(true)
        stepTask = Task { [weak self] in
            await self?.runStep(
                generation: generation,
                delay: delay,
                waitForChange: waitForChange,
                baseline: baseline,
                actAt: actAt
            )
        }
    }

    private func runStep(
        generation: Int,
        delay: Duration,
        waitForChange: Bool,
        baseline: ScreenshotAttachment?,
        actAt: Date
    ) async {
        defer {
            if stepGeneration == generation {
                stepTask = nil
                stepCaptured = false
                stepReading = false
                onReading?(false)
            }
        }
        var settle: StableScreenCaptureResult?
        do {
            if delay > .zero { try await Task.sleep(for: delay) }
            // Without a baseline there is nothing to watch for change against;
            // the eye then takes its own picture once the delay is over.
            if let baseline {
                settle = try await StableScreenCaptureService.capture(
                    after: baseline,
                    waitForChange: waitForChange
                )
            }
        } catch {
            guard !Task.isCancelled, stepGeneration == generation, isActive else { return }
            // The screen could not be captured; the loop keeps watching.
            deliver(.failure(elapsedMs: Self.ms(since: actAt)), settle: nil, actAt: actAt)
            return
        }
        guard !Task.isCancelled, stepGeneration == generation, isActive else {
            if let settle { try? FileManager.default.removeItem(at: settle.attachment.url) }
            return
        }
        // From here the step reads a fixed picture (`GuidanceTrigger.disposition`).
        stepCaptured = true
        stepReading = true
        let request = CompanionEye.Request(
            question: goal,
            goal: goal,
            nextStep: true,
            pointsAtCursor: false,
            history: history(),
            previousInstruction: previousInstruction,
            displayID: displayID
        )
        // The eye owns the settled picture from here, whatever happens.
        let reading = await eye.look(request, adopting: settle?.attachment)
        guard !Task.isCancelled, stepGeneration == generation, isActive else { return }
        guard !reading.superseded else {
            // A look the model asked for began while this step was being
            // read. That look is about a later screen and is what the user
            // hears; this one would say a step twice, or an older one.
            Diagnostics.record("companion.guideAct", details: [("act", .literal("overtaken"))])
            return
        }
        deliver(reading.look, settle: settle, actAt: actAt)
    }

    private func deliver(_ look: CompanionEye.Look, settle: StableScreenCaptureResult?, actAt: Date) {
        // The same instruction again (a click that changed nothing, a scroll
        // with nothing marked) is not a step: saying it twice is the broken
        // record the POC fell into (requirements R14). The eye has drawn its
        // mark again; the voice stays quiet.
        // A screen that did change may well need the same words again ("「次へ」
        // を押してください" page after page), so only an unchanged one is a repeat.
        if look.kind == .nextStep, !(settle?.changeObserved ?? false),
           CompanionEye.speakable(look.message) == CompanionEye.speakable(previousInstruction) {
            Diagnostics.record("companion.guideAct", details: [("act", .literal("repeated"))])
            return
        }
        // previousInstruction moves only when the session actually says the
        // step (`update`); a step dropped unspoken is not what the user heard.
        // Its picture is the screen the next act is judged against.
        if look.kind != .failure {
            steps += 1
            eye.pinGuideCapture()
        }
        Diagnostics.record("companion.guideStep", details: [
            ("step", .count(steps)),
            ("kind", .code(look.kind)),
            // The user's whole wait, from the act to the step being ready.
            ("sinceAct", .ms(Self.ms(since: actAt))),
            ("look", .ms(look.elapsedMs)),
            ("marked", .flag(look.marked)),
            ("attempts", .count(settle?.attempts ?? 0)),
            ("changeObserved", .flag(settle?.changeObserved ?? false)),
            ("settled", .flag(settle?.settled ?? false)),
        ])
        if let ending = Self.ending(after: look.kind, steps: steps) { end(ending) }
        onStep?(look)
    }

    private static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }
}
