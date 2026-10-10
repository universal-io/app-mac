import AppKit
import ApplicationServices

/// R18 V2: the companion's eye — what `look_closely` actually does.
///
/// The voice layer sees the screen as a coarse video frame, too coarse to read
/// a button's name (master plan R18 決定4), so anything it says about a place
/// on screen has to come from here. A look is the existing Vision pipeline,
/// unchanged: a full-resolution capture of the working display, the AX
/// candidates and the product identity for that capture, one non-streaming
/// `/ai/vision` call, and the mark on the real screen chosen by the same
/// ladder `VisionSession` uses — the named candidate's measured frame, else
/// the model's own box, else none.
///
/// Lives outside `AppMode` like the session that owns it. Nothing here changes
/// the mode, activates this app, takes focus or touches a recording.
@MainActor
final class CompanionEye {
    struct Line: Equatable {
        enum Role { case user, companion }
        let role: Role
        let text: String
    }

    struct Request: Equatable {
        var question: String
        var goal: String?
        var nextStep: Bool
        var pointsAtCursor: Bool
        /// Recent conversation, oldest first (user = what was heard, companion = previous look messages).
        var history: [Line]
        /// The last instruction given (the previous Look.message), for guidance.
        var previousInstruction: String?
        var displayID: CGDirectDisplayID?
        /// Where the pointer was while the user was talking (Cocoa global).
        /// 「これ」 means that place, not where the pointer is seconds later
        /// when the model gets round to asking.
        var cursor: CGPoint? = nil
    }

    struct Look: Equatable {
        enum Kind: String, Equatable {
            case nextStep, answer, done, consult, observation, failure
        }

        let kind: Kind
        /// result.message with newlines/markdown removed; empty on failure.
        let message: String
        /// Label of the AX candidate that got the mark (nil when the mark came from an annotation box or there is none).
        let markedLabel: String?
        let marked: Bool
        let skillName: String?
        let elapsedMs: Int

        /// The text sent back to the voice model, exactly three lines:
        /// 言うこと: <message or なし>\n種類: <次の一歩|答え|完了|相談|画面の説明|失敗>\n目印: <出した（「label」）|出した|なし>
        /// (「目印」, not 「印」: the voice misread 印 aloud, build 20.)
        ///
        /// Only `message` is offered as something to say. Observations and
        /// candidate names stay out, so the names the voice may speak are the
        /// ones the reader put in its own sentence.
        var toolOutput: String {
            let say = CompanionEye.speakable(message)
            let mark: String
            if marked {
                let label = markedLabel.map { CompanionEye.speakable($0, limit: CompanionEye.markLabelLimit) }
                mark = (label?.isEmpty ?? true) ? "出した" : "出した（「\(label ?? "")」）"
            } else {
                mark = "なし"
            }
            return [
                "言うこと: \(say.isEmpty ? "なし" : say)",
                "種類: \(kind.word)",
                "目印: \(mark)",
            ].joined(separator: "\n")
        }

        static func failure(elapsedMs: Int) -> Look {
            Look(kind: .failure, message: "", markedLabel: nil, marked: false, skillName: nil, elapsedMs: elapsedMs)
        }
    }

    /// One look as the guide needs it: the look, and whether a newer look
    /// began while this one was being read. Only the newest look is current —
    /// an older one is still returned to whoever asked, but it neither marks
    /// the screen nor becomes the baseline, and a step built on it is stale.
    struct Reading {
        let look: Look
        let superseded: Bool
    }

    /// What one look sends, decided from the request alone.
    struct Plan: Equatable {
        let question: String?
        let guidance: ScreenGuidanceContext?
        let pointsAtCursor: Bool
    }

    /// The whole look, capture to mark. The voice model waits in silence while
    /// it runs, so a look that has not finished by then is reported as failed
    /// rather than waited for (`OperationDeadline.visionTurn`, 120 s, is sized
    /// for someone watching a bubble).
    nonisolated static let lookBudget: Duration = .seconds(15)
    /// How much of the conversation travels with a look: enough to carry the
    /// steps already given, which is what keeps guidance from repeating one.
    nonisolated static let historyTurns = 12
    /// The Gateway's limit on a question, a guidance field and a turn
    /// (`MAX_TURN_CHARS`). It counts JavaScript string length, so UTF-16.
    nonisolated static let maxFieldCharacters = 4_000
    /// Appended to every question. The Gateway's prompt is written for a
    /// bubble a person reads, and the question is the one field it treats as
    /// the user's own words, so this is where a look can say the answer will
    /// be heard instead — without changing the prompt every other client gets.
    /// Guidance has no such field; its steps go out as the prompt writes them.
    nonisolated static let voiceNote =
        "（この答えは音声で読み上げます。1〜2文で、ボタンやメニューの名前は画面の文言どおり「」で囲み、場所（左のメニュー、右上など）を添えてください。聞かれたものがこの画面に見えないときは「この画面には見当たりません。」で始め、この画面から開ける中にそれがある見込みの場所があれば1つだけ挙げてください。この画面や開いている設定の中には無いと分かるなら、そう言って、アプリのどこにあるかを1つ挙げてください（この設定を閉じる、でも構いません）。分からなければ「分かりません」と言ってください。）"
    nonisolated static let visibleListLimit = 60
    /// A label longer than this is body text, not a control's name; the voice
    /// model needs to know it is there, not to read it.
    nonisolated static let visibleLabelLimit = 40
    nonisolated static let markLabelLimit = 60
    /// The truncation reasons `/ai/vision` accepts (route.ts
    /// `allowedTruncationReasons`). Any other — today `window_off_capture`,
    /// which the AX walk writes when the frontmost window is on another
    /// display — fails the whole request with 400, so those diagnostics stay
    /// home. Nothing is lost: they are usage numbers, never prompt input.
    nonisolated static let gatewayTruncationReasons: Set<String> = [
        "no_target_app", "unknown_capture_rect", "permission_denied",
        "node_limit", "candidate_limit", "deadline", "not_configured",
    ]
    /// How often a measured mark re-reads where its element is. One AX read
    /// (0.13 ms measured on Chrome, 2026-09-03), no capture.
    private static let followInterval: TimeInterval = 0.2
    /// A hung app must not hold the main thread for the system's six seconds.
    private static let followTimeout: Float = 0.1
    /// Missed reads in a row before the element counts as gone: 0.6 s.
    private static let followMissesToHide = 3

    /// Whether a mark is up, or one is being followed while its element is
    /// scrolled out of the captured screen.
    var isMarking: Bool { overlay.isShowing || followed != nil }
    /// Looks whose answer has not come back yet, the guide's steps included.
    private(set) var looksInFlight = 0
    /// The capture the newest successful look read: what the screen looked
    /// like when the last instruction was given. The guide settles against it.
    private(set) var latestCapture: ScreenshotAttachment?
    /// The capture the current guidance step was read from: the guide's
    /// screen and its settle baseline. A look about something else — another
    /// app, another display — moves `latestCapture`, never this.
    private(set) var guideCapture: ScreenshotAttachment?

    private let overlay: CompanionMarkOverlay
    private let screenshots = ScreenshotCaptureService()
    private var newestLook = 0
    /// DEBUG: where each read's request and answer are kept (nil in release).
    var trace: CompanionTrace?
    private var workers: [Int: Task<Void, Never>] = [:]
    private var followed: Followed?
    private var followTimer: Timer?
    private var isTornDown = false
    /// The app the mark was drawn over. With another app or Space in front it
    /// would point at something else entirely.
    private var markOwnerPID: pid_t?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// A mark with no element to follow (the reader's own box) cannot know
    /// when the page moves under it; the first scroll or click takes it down.
    private var dismissMonitor: Any?

    /// The element a mark stands on, held so the mark can follow it.
    private struct Followed {
        let element: AXUIElement
        let captureRect: CGRect
        let displayID: CGDirectDisplayID?
        var shown: CGRect?
        /// Reads in a row that got no frame back.
        var misses = 0
    }

    private enum Ending {
        case read(Reading)
        case timedOut
    }

    init(overlay: CompanionMarkOverlay) {
        self.overlay = overlay
    }

    // MARK: - Looking

    /// Captures the display, collects AX candidates and app identity, asks /ai/vision, shows or clears the mark, returns the Look.
    /// Never throws: failures come back as kind .failure (and clear the mark). Cancellation (Task cancel) stops early and clears nothing new.
    func lookClosely(_ request: Request) async -> Look {
        await look(request, adopting: nil).look
    }

    /// `lookClosely`, for the guide: `settled` is a capture already taken
    /// once the screen stopped moving, read instead of taking another. The
    /// look owns it from here — adopted as the baseline or deleted.
    func look(_ request: Request, adopting settled: ScreenshotAttachment?) async -> Reading {
        let started = Date()
        guard !isTornDown else {
            if let settled { Self.remove(settled) }
            return Reading(look: .failure(elapsedMs: 0), superseded: true)
        }
        newestLook += 1
        let number = newestLook
        looksInFlight += 1
        defer { looksInFlight -= 1 }

        // The read and the budget race; whichever ends first decides. The
        // read is not awaited past the budget: the AX walk and the identity
        // read run detached and finish on their own clock, and nothing makes
        // a capture or a request answer a cancellation promptly.
        let (endings, ending) = AsyncStream.makeStream(of: Ending.self, bufferingPolicy: .bufferingOldest(1))
        workers[number] = Task {
            let reading = await self.read(request, number: number, started: started, adopting: settled)
            ending.yield(.read(reading))
            ending.finish()
        }
        let watchdog = Task {
            try? await Task.sleep(for: Self.lookBudget)
            guard !Task.isCancelled else { return }
            ending.yield(.timedOut)
            ending.finish()
        }
        var first: Ending?
        // Ends with nil when the caller is cancelled.
        for await value in endings {
            first = value
            break
        }
        watchdog.cancel()
        let worker = workers.removeValue(forKey: number)
        switch first {
        case .read(let reading)?:
            return reading
        case .timedOut?:
            worker?.cancel()
            // The mark up now was put there for an earlier answer, and the
            // voice is about to say it could not see.
            if number == newestLook { clearMarks() }
            recordFailure(since: started, reason: "timeout")
            return Reading(look: .failure(elapsedMs: Self.ms(since: started)), superseded: number != newestLook)
        case nil:
            // Withdrawn: the tool call was cancelled, or the step superseded.
            // Whoever withdrew it owns what the screen shows next.
            worker?.cancel()
            recordFailure(since: started, reason: "cancelled")
            return Reading(look: .failure(elapsedMs: Self.ms(since: started)), superseded: number != newestLook)
        }
    }

    private func read(
        _ request: Request,
        number: Int,
        started: Date,
        adopting settled: ScreenshotAttachment?
    ) async -> Reading {
        // Every capture this look holds is adopted as the baseline or deleted,
        // on every path out.
        var held = settled
        var adopted = false
        defer {
            if !adopted, let held { Self.remove(held) }
        }
        let plan = Self.plan(request)
        guard let client = GatewayVisionClient.make() else {
            return fail(number, since: started, reason: "signedOut")
        }
        guard held != nil || ScreenCapturePermission.isGranted else {
            return fail(number, since: started, reason: "noScreenPermission")
        }
        // 「これ」 is where the pointer was while the user talked; failing
        // that, where it is now, read before anything is awaited.
        let cursor = plan.pointsAtCursor ? (request.cursor ?? NSEvent.mouseLocation) : nil
        let app = Self.frontmostApp()
        let pid = app?.processIdentifier
        // The display the user's app is on now: the session's own display was
        // resolved when it started, and the user may have moved to another.
        let displayID = ActiveDisplay.displayID(of: ActiveDisplay.workingScreen(of: app)) ?? request.displayID
        // Alongside the capture, as Vision's summon does: the Skill (GA4 and
        // the rest) is chosen from the host this finds.
        let identityTask = VisionObservationCaptureService.identityTask(preferredPID: pid)
        do {
            let capture: ScreenshotAttachment
            if let held {
                capture = held
            } else {
                capture = try await screenshots.captureFullScreen(displayID: displayID)
                held = capture
            }
            try Task.checkCancellation()
            let snapshot = await VisionObservationCaptureService.captureTask(
                preferredPID: pid,
                attachment: capture
            ).value
            try Task.checkCancellation()
            let identity = await identityTask.value
            try Task.checkCancellation()
            let pointer = cursor.flatMap { location in
                capture.captureRect.flatMap { captureRect in
                    Self.pointer(
                        atCocoa: location,
                        mainDisplayHeight: VisionPointerResolver.mainDisplayHeight,
                        captureRect: captureRect,
                        candidates: snapshot.axCandidates
                    )
                }
            }
            let traceNumber = trace?.nextLook() ?? 0
            let response = try await client.understand(
                attachment: capture,
                question: plan.question,
                turns: Self.wireTurns(request.history),
                candidates: snapshot.axCandidates,
                candidateDiagnostics: Self.wireDiagnostics(snapshot.diagnostics),
                identity: identity,
                pointer: pointer,
                guidanceContext: plan.guidance,
                // The voice speaks Japanese whatever the Mac's language is;
                // Vision otherwise follows the device (AppSettings).
                language: .japanese,
                wire: trace.map { trace in
                    { request, response in trace.saveLook(traceNumber, request: request, response: response) }
                }
            )
            try Task.checkCancellation()
            let isNewest = number == newestLook && !isTornDown
            var marked = false
            var markedLabel: String?
            if isNewest {
                (marked, markedLabel) = mark(
                    response.result,
                    candidates: snapshot.axCandidates,
                    handles: snapshot.handles,
                    capture: capture,
                    displayID: displayID,
                    ownerPID: pid
                )
                adopt(capture)
                adopted = true
            }
            let look = Look(
                kind: Self.kind(for: response.result.mode, guidance: plan.guidance != nil),
                message: Self.spokenMessage(response.result.message),
                markedLabel: markedLabel,
                marked: marked,
                skillName: response.skillName,
                elapsedMs: Self.ms(since: started)
            )
            Diagnostics.record("companion.look", details: [
                ("ms", .ms(look.elapsedMs)),
                ("kind", .code(look.kind)),
                ("marked", .flag(look.marked)),
                ("candidates", .count(snapshot.axCandidates.count)),
                ("skill", .flag(look.skillName != nil)),
                ("guidance", .flag(plan.guidance != nil)),
                ("pointer", .flag(pointer != nil)),
                ("superseded", .flag(!isNewest)),
                ("truncated", .code(AXTruncationCode(snapshot.diagnostics.truncatedReason))),
            ])
            trace?.record("read", [
                "n": traceNumber,
                "question": plan.question ?? "",
                "guided": plan.guidance != nil,
                "kind": "\(look.kind)",
                "said": look.message,
                "marked": look.markedLabel ?? "",
                "candidates": snapshot.axCandidates.count,
                "ms": look.elapsedMs,
                "superseded": !isNewest,
            ])
            return Reading(look: look, superseded: !isNewest)
        } catch {
            // Cancelled from outside, as `CancellationError` or — mid-request
            // — as `URLError.cancelled`: whoever cancelled owns the outcome
            // and has recorded it, and nothing on screen is this look's to
            // change.
            guard !Task.isCancelled else {
                return Reading(look: .failure(elapsedMs: Self.ms(since: started)), superseded: number != newestLook)
            }
            return fail(number, since: started, reason: "read", error: error)
        }
    }

    /// A failed look leaves no mark: the one up was put there for an earlier
    /// answer, and the voice is about to say it could not see. Only the newest
    /// look may take it down — an older one failing late says nothing about
    /// the screen the newer one read.
    private func fail(_ number: Int, since started: Date, reason: StaticString, error: Error? = nil) -> Reading {
        if number == newestLook, !isTornDown { clearMarks() }
        recordFailure(since: started, reason: reason, error: error)
        return Reading(look: .failure(elapsedMs: Self.ms(since: started)), superseded: number != newestLook)
    }

    private func recordFailure(since started: Date, reason: StaticString, error: Error? = nil) {
        var details: [(StaticString, DiagnosticValue)] = [
            ("ms", .ms(Self.ms(since: started))),
            ("kind", .code(Look.Kind.failure)),
            ("marked", .flag(false)),
            ("reason", .literal(reason)),
        ]
        if let error { details.append(("error", .code(DiagnosticErrorClass(error)))) }
        Diagnostics.record("companion.look", details: details)
    }

    /// The newest capture becomes the baseline and the one before it goes:
    /// a session asks many times, and each capture is a full-screen PNG.
    private func adopt(_ capture: ScreenshotAttachment) {
        if let previous = latestCapture, previous.id != capture.id, previous.id != guideCapture?.id {
            Self.remove(previous)
        }
        latestCapture = capture
    }

    /// The newest look gave a step: its capture becomes what guidance judges
    /// the user's next act against.
    func pinGuideCapture() {
        guard let latestCapture, latestCapture.id != guideCapture?.id else { return }
        if let previous = guideCapture { Self.remove(previous) }
        guideCapture = latestCapture
    }

    /// The app the user is working in. This app never becomes frontmost — the
    /// companion's window does not activate — so the frontmost app is theirs;
    /// if it somehow is this one, the capture service's own fallback (the
    /// owner of the frontmost real window) decides.
    private static func frontmostPID() -> pid_t? {
        frontmostApp()?.processIdentifier
    }

    private static func frontmostApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return app
    }

    // MARK: - The mark

    func clearMarks() {
        stopFollowing()
        removeMarkWatchers()
        overlay.clear()
        markOwnerPID = nil
    }

    /// The ladder `VisionSession.answerHighlight` defines, unchanged. A
    /// target that cannot be placed is tolerated: the sentence is what the
    /// user asked for, and losing it over a missing rectangle is the wrong
    /// trade.
    private func mark(
        _ result: VisionResult,
        candidates: [VisionObservation.Candidate],
        handles: VisionObservationCaptureService.CandidateHandles,
        capture: ScreenshotAttachment,
        displayID: CGDirectDisplayID?,
        ownerPID: pid_t?
    ) -> (marked: Bool, label: String?) {
        guard let captureRect = capture.captureRect,
              let resolution = try? VisionSession.answerHighlight(
                for: result,
                candidates: candidates,
                toleratingUnplaceableTarget: true
              )
        else {
            clearMarks()
            return (false, nil)
        }
        switch resolution {
        case .candidate(let index, let rect):
            let candidate = candidates[index]
            show(rect, captureRect: captureRect, displayID: displayID,
                 following: handles.byID[candidate.id], ownerPID: ownerPID)
            return (true, candidate.label)
        case .annotation(let box):
            show(box, captureRect: captureRect, displayID: displayID, following: nil, ownerPID: ownerPID)
            return (true, nil)
        case .gestureKept, .none:
            clearMarks()
            return (false, nil)
        }
    }

    /// A measured mark keeps standing on its element while the page moves
    /// under it, as guidance's frame does — but polled rather than driven by
    /// scroll events, because outside guidance nothing here watches events.
    private func show(
        _ rect: CGRect,
        captureRect: CGRect,
        displayID: CGDirectDisplayID?,
        following element: AXUIElement?,
        ownerPID: pid_t?
    ) {
        stopFollowing()
        removeMarkWatchers()
        overlay.show([rect], captureRect: captureRect, displayID: displayID)
        markOwnerPID = ownerPID
        watchForAnotherApp()
        guard let element else {
            dismissOnFirstMove()
            return
        }
        AXUIElementSetMessagingTimeout(element, Self.followTimeout)
        followed = Followed(element: element, captureRect: captureRect, displayID: displayID, shown: rect)
        let timer = Timer(timeInterval: Self.followInterval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.follow()
            }
        }
        // Common modes, so the mark keeps up while this app's own window is
        // being dragged.
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
        // At once, not a tick later: the read took seconds, and the page may
        // have moved under the rectangle the capture measured.
        follow()
    }

    /// Moves the mark onto where its element is now; hides it while the
    /// element is outside the captured screen; takes it down when the element
    /// is gone — a control that answers nothing left with the screen it was on.
    private func follow() {
        guard var followed else {
            stopFollowing()
            return
        }
        // Another app or Space in front: the element still reports where it
        // is, but the frame would sit over whatever covers it now. Hidden,
        // still followed; back in front, it is drawn again.
        if let owner = markOwnerPID, Self.frontmostPID() != owner {
            hide(&followed)
            return
        }
        guard let frame = VisionObservationCaptureService.frame(of: followed.element) else {
            // A busy app times out exactly as a vanished element fails, so one
            // missed read is not yet "gone"; a few in a row are.
            followed.misses += 1
            self.followed = followed
            guard followed.misses >= Self.followMissesToHide else { return }
            clearMarks()
            Diagnostics.record("companion.markHidden", details: [("reason", .literal("gone"))])
            return
        }
        followed.misses = 0
        self.followed = followed
        // The element answers for its window even when that window is
        // minimized or on another Space; only a window the window server is
        // showing gets the frame.
        if let owner = markOwnerPID, !Self.window(of: owner, onScreenAround: frame) {
            hide(&followed)
            return
        }
        let visible = VisionPointerResolver.normalized(frame, within: followed.captureRect)
        guard !Self.isSamePlace(visible, followed.shown, in: followed.captureRect) else { return }
        if let visible {
            overlay.show([visible], captureRect: followed.captureRect, displayID: followed.displayID)
        } else {
            overlay.clear()
        }
        followed.shown = visible
        self.followed = followed
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        followed = nil
    }

    private func hide(_ followed: inout Followed) {
        guard followed.shown != nil else { return }
        overlay.clear()
        followed.shown = nil
        self.followed = followed
    }

    /// Whether one of the app's windows that is on screen now contains the
    /// centre of `frame` (CG global coordinates, as AX reports them).
    private static func window(of pid: pid_t, onScreenAround frame: CGRect) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return true }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"]
            else { return false }
            return CGRect(x: x, y: y, width: width, height: height).contains(centre)
        }
    }

    /// App and Space changes, for as long as a mark is up.
    private func watchForAnotherApp() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.anotherAppMayBeInFront() }
            })
        }
    }

    private func anotherAppMayBeInFront() {
        if followed != nil {
            follow()
        } else if markOwnerPID != nil {
            // A box with no element behind it cannot be followed back to
            // where it belongs: another app or Space in front, and it goes.
            clearMarks()
        }
    }

    private func dismissOnFirstMove() {
        // Keys too: Space, Page Down and the arrows scroll without a wheel.
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.followed == nil, self.markOwnerPID != nil else { return }
                self.clearMarks()
                Diagnostics.record("companion.markHidden", details: [("reason", .literal("moved"))])
            }
        }
    }

    private func removeMarkWatchers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
        if let dismissMonitor { NSEvent.removeMonitor(dismissMonitor) }
        dismissMonitor = nil
    }

    // MARK: - What is visible

    /// AX-only snapshot of the frontmost app on that display (no screenshot), formatted for the voice model:
    /// "いま見えている要素（アプリが取得、HH:mm:ss）:\n- 左上 ボタン「保存」\n..." at most 60 lines; nil when AX is unavailable or nothing was found.
    ///
    /// Not fast: the walk always makes a second pass half a second after the
    /// first (a cold browser has no web area yet; a warm one is still
    /// growing), so taking it when the user starts talking is what puts it
    /// there before their turn ends.
    func visibleList(displayID: CGDirectDisplayID?) async -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let started = Date()
        let app = Self.frontmostApp()
        let working = ActiveDisplay.displayID(of: ActiveDisplay.workingScreen(of: app)) ?? displayID
        // The walk reads only the rectangle and the scope of the attachment it
        // is given — it clips and normalizes to them — so a picture is
        // neither taken nor read.
        let probe = ScreenshotAttachment(
            url: URL(fileURLWithPath: "/dev/null"),
            captureScope: .display,
            captureRect: CGDisplayBounds(working ?? CGMainDisplayID())
        )
        let snapshot = await VisionObservationCaptureService.captureTask(
            preferredPID: app?.processIdentifier,
            attachment: probe
        ).value
        guard !Task.isCancelled else { return nil }
        let text = Self.visibleListText(snapshot.axCandidates, at: Date())
        Diagnostics.record("companion.visibleList", details: [
            ("ms", .ms(Self.ms(since: started))),
            ("candidates", .count(snapshot.axCandidates.count)),
            ("truncated", .code(AXTruncationCode(snapshot.diagnostics.truncatedReason))),
        ])
        return text
    }

    // MARK: - Ending

    /// Deletes temporary capture files; called when the session ends.
    func tearDown() {
        isTornDown = true
        workers.values.forEach { $0.cancel() }
        workers.removeAll()
        clearMarks()
        if let latestCapture { Self.remove(latestCapture) }
        if let guideCapture, guideCapture.id != latestCapture?.id { Self.remove(guideCapture) }
        latestCapture = nil
        guideCapture = nil
    }

    private static func remove(_ capture: ScreenshotAttachment) {
        try? FileManager.default.removeItem(at: capture.url)
    }

    private static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }
}

// MARK: - The request

extension CompanionEye {
    /// Question or guidance, never both (the route rejects the pair).
    ///
    /// Guidance needs the instruction it continues from and a goal to measure
    /// against; a "next step" without either is asked as a question instead,
    /// which still reads the screen. A pointer goes with questions only: in
    /// guidance its prompt block competes with "the user has acted since the
    /// previous capture".
    nonisolated static func plan(_ request: Request) -> Plan {
        let instruction = clipped(trimmed(request.previousInstruction))
        let goal = clipped(trimmed(request.goal).isEmpty ? trimmed(request.question) : trimmed(request.goal))
        if request.nextStep, !instruction.isEmpty, !goal.isEmpty {
            return Plan(
                question: nil,
                guidance: ScreenGuidanceContext(goal: goal, previousInstruction: instruction),
                pointsAtCursor: false
            )
        }
        return Plan(question: spokenQuestion(request.question), guidance: nil, pointsAtCursor: request.pointsAtCursor)
    }

    /// The question with the voice note on a line of its own, cut so the two
    /// together fit the Gateway's limit. Nil for an empty question: the look
    /// then asks for the screen's description, which is what a wordless look
    /// can honestly answer.
    nonisolated static func spokenQuestion(_ question: String) -> String? {
        let asked = trimmed(question)
        guard !asked.isEmpty else { return nil }
        let room = maxFieldCharacters - voiceNote.utf16.count - 1
        return clipped(asked, toUTF16: room) + "\n" + voiceNote
    }

    /// The conversation as Vision turns: what was heard is the user's, what
    /// the eye said is the assistant's. Empty lines are dropped; the newest
    /// twelve travel.
    nonisolated static func wireTurns(_ history: [Line]) -> [VisionTurn] {
        let turns = history.compactMap { line -> VisionTurn? in
            let text = clipped(trimmed(line.text))
            guard !text.isEmpty else { return nil }
            return VisionTurn(role: line.role == .user ? .user : .assistant, text: text)
        }
        return Array(turns.suffix(historyTurns))
    }

    nonisolated static func wireDiagnostics(
        _ diagnostics: VisionObservationCaptureService.Diagnostics
    ) -> VisionObservationCaptureService.Diagnostics? {
        guard let reason = diagnostics.truncatedReason else { return diagnostics }
        return gatewayTruncationReasons.contains(reason) ? diagnostics : nil
    }

    /// Where the pointer is, as Vision's pointing turn sends it: a point in
    /// the capture's normalized space and the smallest candidate under it. Nil
    /// when the pointer is on a display this capture does not cover.
    nonisolated static func pointer(
        atCocoa location: CGPoint,
        mainDisplayHeight: CGFloat,
        captureRect: CGRect,
        candidates: [VisionObservation.Candidate]
    ) -> VisionPointer? {
        let global = VisionPointerResolver.globalCGPoint(cocoaGlobal: location, mainDisplayHeight: mainDisplayHeight)
        guard let point = VisionPointerResolver.normalized(global, within: captureRect) else { return nil }
        return VisionPointer(
            kind: .point(point),
            hitCandidateID: VisionPointerResolver.candidate(at: point, in: candidates)?.id
        )
    }

    /// Cut to what the Gateway accepts. Its limits are JavaScript string
    /// lengths — UTF-16 units — so that is what is counted, and the cut falls
    /// between characters.
    nonisolated static func clipped(_ text: String, toUTF16 limit: Int = maxFieldCharacters) -> String {
        guard text.utf16.count > limit else { return text }
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let width = text[index].utf16.count
            guard used + width <= limit else { break }
            used += width
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    nonisolated private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The answer

extension CompanionEye {
    /// A guidance turn that comes back as an answer is the goal reached; the
    /// same mode for a question is just its answer.
    nonisolated static func kind(for mode: VisionResult.Mode, guidance: Bool) -> Look.Kind {
        switch mode {
        case .guide: return .nextStep
        case .answer: return guidance ? .done : .answer
        case .clarification: return .consult
        case .observation: return .observation
        }
    }

    /// The message as one line of plain text: what a person reading it aloud
    /// would skip is taken out, and nothing else is changed — the names inside
    /// 「」 are the ones the voice must repeat exactly.
    nonisolated static func spokenMessage(_ raw: String) -> String {
        var spoken = ""
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = plainLine(rawLine)
            guard let first = line.first else { continue }
            if let last = spoken.last {
                // Words in Latin script need their space back; a Japanese line
                // that ended without punctuation gets one as its pause.
                if (last.isASCII && first.isASCII) || !closesPhrase(last) { spoken += " " }
            }
            spoken += line
        }
        return spoken
    }

    /// Markdown off one line: block markers at its start, emphasis and code
    /// marks anywhere, and links down to their words.
    nonisolated private static func plainLine(_ raw: String) -> String {
        var line = raw.replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let blockMarkers = [
            #"^#{1,6}\s+"#,
            #"^>\s*"#,
            #"^[-*+]\s+"#,
            #"^[・•]\s*"#,
            #"^\d{1,3}[.)]\s+"#,
            #"^\d{1,3}[．）]\s*"#,
        ]
        for pattern in blockMarkers {
            line = line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        line = line.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        for mark in ["**", "__", "`"] {
            line = line.replacingOccurrences(of: mark, with: "")
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    nonisolated private static func closesPhrase(_ character: Character) -> Bool {
        "。．！？、，：；」』）】〕》〉….!?,:;)]}".contains(character)
    }

    /// One line, whitespace collapsed, and — when a limit is given — cut with
    /// an ellipsis.
    nonisolated static func speakable(_ text: String, limit: Int? = nil) -> String {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let line = words.joined(separator: " ")
        guard let limit, line.count > limit else { return line }
        return String(line.prefix(limit)) + "…"
    }

    /// Whether two marks would be drawn in the same place, to the half point.
    /// AX frames jitter by fractions of a point between reads, and redrawing
    /// for that would restart the mark's beat five times a second.
    nonisolated static func isSamePlace(_ a: CGRect?, _ b: CGRect?, in captureRect: CGRect) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (a?, b?):
            let tolerance: CGFloat = 0.5
            return abs(a.minX - b.minX) * captureRect.width < tolerance
                && abs(a.minY - b.minY) * captureRect.height < tolerance
                && abs(a.width - b.width) * captureRect.width < tolerance
                && abs(a.height - b.height) * captureRect.height < tolerance
        default:
            return false
        }
    }
}

// MARK: - The visible list

extension CompanionEye {
    /// The candidates as the voice model reads them: one line each, in reading
    /// order, with where on the screen, what kind of control, its name, and
    /// the states a person would mention. Nil when there is nothing to list.
    nonisolated static func visibleListText(
        _ candidates: [VisionObservation.Candidate],
        at date: Date,
        timeZone: TimeZone = .current
    ) -> String? {
        var seen = Set<String>()
        var lines: [String] = []
        for candidate in readingOrder(candidates) {
            guard lines.count < visibleListLimit else { break }
            let label = speakable(candidate.label, limit: visibleLabelLimit)
            guard !label.isEmpty else { continue }
            let role = roleWord(candidate.role)
            // Twenty "削除" buttons down a table are one fact to the voice.
            guard seen.insert(role + "\u{1F}" + label).inserted else { continue }
            let place = candidate.rect.map { placeWord($0) + " " } ?? ""
            let states = stateWords(candidate.states)
            let suffix = states.isEmpty ? "" : "（" + states.joined(separator: "、") + "）"
            lines.append("- \(place)\(role)「\(label)」\(suffix)")
        }
        guard !lines.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        let header = "いま見えている要素（アプリが取得、\(formatter.string(from: date))）:"
        return ([header] + lines).joined(separator: "\n")
    }

    /// Top to bottom, then left to right. Elements whose centres sit within
    /// about a line's height of each other read as one row — a 1pt
    /// difference in where two toolbar buttons start must not put the right
    /// one first.
    nonisolated static func readingOrder(
        _ candidates: [VisionObservation.Candidate]
    ) -> [VisionObservation.Candidate] {
        let rowTolerance: CGFloat = 0.012
        let placed = candidates
            .compactMap { candidate in candidate.rect.map { (candidate: candidate, rect: $0) } }
            .sorted { $0.rect.midY < $1.rect.midY }
        var rows: [[(candidate: VisionObservation.Candidate, rect: CGRect)]] = []
        for item in placed {
            if let rowTop = rows.last?.first?.rect.midY, item.rect.midY - rowTop <= rowTolerance {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        let ordered = rows.flatMap { row in row.sorted { $0.rect.minX < $1.rect.minX }.map(\.candidate) }
        return ordered + candidates.filter { $0.rect == nil }
    }

    /// Where on the screen, in the words a person uses: the screen in thirds
    /// each way, read from the element's centre.
    nonisolated static func placeWord(_ rect: CGRect) -> String {
        let column = rect.midX < 1.0 / 3 ? 0 : (rect.midX > 2.0 / 3 ? 2 : 1)
        let row = rect.midY < 1.0 / 3 ? 0 : (rect.midY > 2.0 / 3 ? 2 : 1)
        return [
            ["左上", "上", "右上"],
            ["左", "中央", "右"],
            ["左下", "下", "右下"],
        ][row][column]
    }

    /// The collector writes roles lowercased without "AX" ("menuitem",
    /// "popupbutton"); AX's own spelling is accepted too.
    nonisolated static func roleWord(_ role: String?) -> String {
        var key = (role ?? "").lowercased()
        if key.hasPrefix("ax") { key.removeFirst(2) }
        key = key.filter(\.isLetter)
        switch key {
        case "button": return "ボタン"
        case "link": return "リンク"
        case "tab": return "タブ"
        case "menuitem", "menu", "menubutton", "menubaritem": return "メニュー"
        case "textfield", "searchfield", "textarea": return "入力欄"
        case "checkbox": return "チェックボックス"
        case "radio", "radiobutton": return "ラジオボタン"
        case "popup", "popupbutton", "combobox": return "選択欄"
        case "heading": return "見出し"
        case "statictext", "text": return "文字"
        default: return "要素"
        }
    }

    /// The states worth saying. Focus is left out: in a list taken while the
    /// user talks to the companion, it says nothing about the screen.
    nonisolated static func stateWords(_ states: [String]) -> [String] {
        let words: [String: String] = [
            "selected": "選択中",
            "disabled": "無効",
            "expanded": "開いている",
            "checked": "オン",
        ]
        var spoken: [String] = []
        for state in states {
            guard let word = words[state], !spoken.contains(word) else { continue }
            spoken.append(word)
        }
        return spoken
    }
}

extension CompanionEye.Look.Kind: DiagnosticCode {
    /// What the voice model is told the look was.
    var word: String {
        switch self {
        case .nextStep: return "次の一歩"
        case .answer: return "答え"
        case .done: return "完了"
        case .consult: return "相談"
        case .observation: return "画面の説明"
        case .failure: return "失敗"
        }
    }

    var diagnosticCode: String { rawValue }
}
