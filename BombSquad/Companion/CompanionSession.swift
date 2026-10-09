import AppKit

/// R18: one conversation with the companion — the connection, its ears and
/// mouth, its eye — from the double-tap that starts it to the one that ends it.
///
/// Lives outside `AppMode` on purpose (master plan R18 決定5): the user keeps
/// working in other apps the whole time, and Vision's `close()` stops
/// recording as a side effect.
///
/// Turns are decided on this Mac (`CompanionTurnTaker`): the session is opened
/// with the server's own turn detection off, so the server hears only what
/// the user says between activityStart and activityEnd. Two rules keep a
/// noise from becoming a conversation:
/// - an answer is played only once the server has transcribed words for the
///   user's turn; a turn that ends without words loses its answer, and a
///   voice paused for it resumes;
/// - nothing is played while the user is talking.
///
/// The eye is the existing Vision pipeline (`CompanionEye`): look_closely
/// reads the screen with AX candidates, marks the target on the real screen,
/// and the model speaks only what came back. After a step, `CompanionGuide`
/// watches for the user's action and reads the next one.
@MainActor
final class CompanionSession: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case listening
        /// The user is talking.
        case hearing
        /// The eye is reading the screen.
        case looking
        case speaking
        case reconnecting
        case failed(String)
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var transcript = CompanionTranscript()
    @Published private(set) var isMuted = false
    /// The microphone, 0...1, for the window's meter.
    @Published private(set) var inputLevel: Float = 0
    /// False when the audio could only start without echo cancellation.
    @Published private(set) var cancelsEcho = true
    /// The Skill the last look applied (master plan R18 決定2: shown, never silent).
    @Published private(set) var skillName: String?

    /// The voice of the POC sessions the owner rated well (2026-10-08 logs).
    static let voice = "Zephyr"
    private static let setupTimeout: TimeInterval = 10
    private static let maxReconnectAttempts = 3
    private static let levelInterval: TimeInterval = 1.0 / 15
    /// The list of what is on screen is read again after this long even when
    /// nothing seems to have changed (requirements R9).
    private static let visibleListStale: TimeInterval = 30
    /// The answer to a turn without words starts to arrive: this long for the
    /// words to catch up before a voice paused for that turn carries on.
    private static let noWordsGrace: Duration = .milliseconds(500)
    /// A GoAway gives this long or so; the handover waits for a quiet moment
    /// within it.
    private static let defaultHandOverWindow: TimeInterval = 8
    private static let lookTool = "look_closely"

    let displayID: CGDirectDisplayID?
    private let tokenClient: CompanionTokenClient
    private let targetApp: NSRunningApplication?
    private let audio = CompanionAudio()
    private let screen = CompanionScreenFeed()
    private let uplink = LiveUplink()
    private let marks = CompanionMarkOverlay()
    private lazy var eye = CompanionEye(overlay: marks)
    /// DEBUG: the conversation in words, for reading a session back (nil in release).
    private var trace: CompanionTrace?
    private lazy var guide = CompanionGuide(eye: eye)
    /// The window's frame, so the guide does not take clicks on it for steps.
    var panelFrame: () -> NSRect? = { nil }

    private var socket: LiveSocket?
    private var receiveTask: Task<Void, Never>?
    private var identityTask: Task<VisionObservationCaptureService.TargetIdentity?, Never>?
    private var resumeHandle: String?
    /// The last frame the feed produced, sent again on every (re)connect.
    private var latestFrame: Data?
    private var framesSeen = 0
    private var isStopped = false
    private var isReconnecting = false
    private var reconnectAttempts = 0
    /// Set by a GoAway: the new connection is adopted at a quiet moment
    /// before this, rather than mid-turn.
    private var handOverBy: Date?
    private let startedAt = Date()
    private var lastLevelPublish = Date.distantPast

    // The floor.
    private var userSpeaking = false
    private var voiceAudible = false
    /// The user talked over the voice; it is paused until words settle it.
    private var talkOverPending = false
    /// The paused voice was let go on before the words could settle it.
    private var resumedEarly = false
    private enum Reply: Equatable {
        /// Answers play as they come.
        case open
        /// The user's last turn has no words yet: answers wait.
        case awaitingWords
    }
    private var reply: Reply = .open
    private var heardThisTurn = false
    /// Whether the server saw the start of the user's latest turn (not before
    /// the connection opened, nor across a reconnect).
    private var lastStartDelivered = false
    /// Whether the end of that turn reached a connection.
    private var lastEndDelivered = false
    /// The server owes an answer: a turn of the user's ended there, or this
    /// session sent a turn or a tool result. A turn of our own sent meanwhile
    /// would cut that answer off.
    private var serverTurnOpen = false
    /// Answer audio waiting for words, or for the user to finish.
    private var heldAudio: [Data] = []
    /// What was left of an answer the user talked over, if it was not a person.
    private var resumeAudio: [Data] = []
    private var noWordsTask: Task<Void, Never>?
    private var turnEndedAt: Date?
    private var replyMeasured = true
    /// The server ends the answer it just interrupted with a turnComplete of
    /// its own; that one is not the end of the user's turn.
    private var interruptedTurnPending = false
    /// Where the pointer was while the user was last heard talking.
    private var turnCursor: CGPoint?

    // What was said, shown once it has been heard.
    private var pendingSaid: [(generation: Int, frame: Int, text: String)] = []
    private var heldFrames = 0

    // The greeting.
    private var greetingPending = false
    private var greetingSpoke = false
    private var greetingRetried = false

    // The eye.
    private var looks: [String: Task<Void, Never>] = [:]
    private var guideReading = false
    /// The last step the companion gave (a Look.message of kind next step).
    private var lastInstruction: String?
    /// What the user is trying to get done, held here, not by the model: a
    /// look without a goal ("次は？", "それ違いますよ") keeps it. Build 20 let
    /// such questions become the goal and the guidance forgot its purpose.
    private var currentGoal: String?
    private var lines: [CompanionEye.Line] = []
    private var pendingStep: CompanionEye.Look?
    /// 田中さん's answer to a look, waiting for a quiet moment to go to the
    /// voice as a turn of its own: the look itself was answered at once.
    private var pendingAnswer: (look: CompanionEye.Look, goal: String?)?
    /// A turn the model answers with silence brings no turnComplete (probed
    /// on 3.1 Flash Live); this takes the floor back after `silentTurnLimit`.
    private var turnWatchdog: Task<Void, Never>?
    private static let silentTurnLimit: Duration = .seconds(8)
    /// What a look_closely call is answered with at once (Gateway
    /// `LiveLook` "async"): the voice says one line and keeps talking while
    /// 田中さん reads; the answer follows as a 「（田中さんから）」 turn.
    static let lookAcknowledgement = "田中さんが確認中です。結果が届くまで、画面について推測で答えないでください。"
    /// A step sent as a turn: it becomes the instruction in force only once
    /// that turn completes uninterrupted, i.e. the user heard it.
    private var stepInFlight: CompanionEye.Look?
    private var visibleListTask: Task<Void, Never>?
    private var lastVisibleListAt = Date.distantPast
    private var lastVisibleListFrames = -1
    private var lastVisibleListPID: pid_t?
    private var lastVisibleListText: String?

    init?(targetApp: NSRunningApplication?, displayID: CGDirectDisplayID?) {
        guard let tokenClient = CompanionTokenClient.make() else { return nil }
        self.tokenClient = tokenClient
        self.targetApp = targetApp
        self.displayID = displayID
    }

    var statusText: String {
        switch phase {
        case .connecting: return "つないでいます…"
        case .listening:
            if isMuted { return "ミュート中" }
            return cancelsEcho ? "聞いています" : "聞いています・ヘッドホン推奨"
        case .hearing: return "聞き取っています"
        case .looking: return "画面を確認しています"
        case .speaking: return "話しています"
        case .reconnecting: return "つなぎ直しています…"
        case .failed: return "止まりました"
        }
    }

    /// Why it stopped, for the conversation area (the header has one line).
    var failureMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    func start() {
        Diagnostics.record("companion.started")
        trace = CompanionTrace.start()
        eye.trace = trace
        identityTask = VisionObservationCaptureService.identityTask(
            preferredPID: targetApp?.processIdentifier
        )
        // The eye's route is cold until the first look; warming it costs no model call.
        Task { await GatewayAIWarmup.warm([.vision]) }
        wire()
        Task { [weak self] in
            await self?.startScreen()
        }
        Task { [weak self] in
            guard let self, await self.prepareMicrophone() else { return }
            // The token and the socket do not need the main thread; the audio
            // engine does, and takes about a second. Side by side.
            let client = tokenClient
            async let opened = Self.open(client: client, handle: nil)
            let audioStarted = startAudio()
            do {
                let socket = try await opened
                guard audioStarted, !isStopped else {
                    socket.close()
                    return
                }
                adopt(socket, resuming: false, since: startedAt)
                await greet(on: socket)
                refreshPhase()
                refreshVisibleList(force: true)
            } catch {
                guard !isStopped else { return }
                Diagnostics.record("companion.connectFailed", details: [
                    ("resuming", .flag(false)),
                    ("attempt", .count(0)),
                    ("error", .code(DiagnosticErrorClass(error))),
                ])
                fail(UserFacingError.message(for: error))
            }
        }
    }

    func stop() {
        guard !isStopped else { return }
        tearDown()
        Diagnostics.record("companion.ended", details: [
            ("duration", .ms(Self.ms(since: startedAt))),
            ("frames", .count(framesSeen)),
        ])
    }

    func toggleMute() {
        isMuted.toggle()
        audio.setMuted(isMuted)
        Diagnostics.record("companion.muted", details: [("on", .flag(isMuted))])
        refreshPhase()
    }

    // MARK: - Start

    private func wire() {
        audio.onUplink = { [weak self, uplink] message in
            switch message {
            case .start:
                let delivered = uplink.sendActivity(start: true)
                // Queued before the audio's own report of the start, so the
                // session knows by then whether the server saw it.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.lastStartDelivered = delivered }
                }
            case .audio(let pcm):
                uplink.send(LiveWire.audio(pcm))
            case .end:
                // An end that went out means an answer is coming; one that
                // could not (the connection dropped mid-turn) means none will.
                let delivered = uplink.sendActivity(start: false)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.lastEndDelivered = delivered
                        if delivered { self?.serverTurnOpen = true }
                    }
                }
            }
        }
        audio.onUserTurn = { [weak self] turn in
            MainActor.assumeIsolated { self?.userTurn(turn) }
        }
        audio.onSpeakingChanged = { [weak self] isSpeaking in
            MainActor.assumeIsolated { self?.speakingChanged(isSpeaking) }
        }
        audio.onPlayed = { [weak self] generation, frames in
            MainActor.assumeIsolated { self?.revealSaid(generation: generation, played: frames) }
        }
        audio.onInputLevel = { [weak self] level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.publishInputLevel(level) }
            }
        }
        audio.onRestarted = { [weak self] plan in
            MainActor.assumeIsolated { self?.audioRestarted(plan) }
        }
        screen.onFrame = { [weak self, uplink] jpeg in
            uplink.send(LiveWire.video(jpeg: jpeg))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.latestFrame = jpeg
                    self?.framesSeen += 1
                }
            }
        }
        guide.onStep = { [weak self] look in
            self?.stepRead(look)
        }
        guide.onReading = { [weak self] reading in
            self?.guideReading = reading
            self?.refreshPhase()
        }
    }

    private func startScreen() async {
        guard ScreenCapturePermission.isGranted else {
            Diagnostics.record("companion.screenUnavailable")
            return
        }
        do {
            try await screen.start(displayID: displayID)
        } catch {
            Diagnostics.record("companion.screenFailed", details: [
                ("error", .code(DiagnosticErrorClass(error))),
            ])
        }
    }

    private func prepareMicrophone() async -> Bool {
        if MicrophonePermission.isGranted { return true }
        let message = "声の相棒にはマイクの許可が必要です。システム設定の"
            + "「プライバシーとセキュリティ」からマイクを許可してください。"
        guard !MicrophonePermission.isDenied else {
            fail(message)
            return false
        }
        let granted = await withCheckedContinuation { continuation in
            MicrophonePermission.request { continuation.resume(returning: $0) }
        }
        if !granted { fail(message) }
        return granted && !isStopped
    }

    private func startAudio() -> Bool {
        do {
            try audio.start()
            cancelsEcho = audio.plan == .voiceProcessing
            return true
        } catch {
            Diagnostics.record("companion.audioFailed", details: [
                ("error", .code(DiagnosticErrorClass(error))),
            ])
            fail(UserFacingError.message(for: error))
            return false
        }
    }

    /// A device came or went and the audio was built again. Without a
    /// microphone there is no conversation: the window says so instead of
    /// listening to nothing.
    private func audioRestarted(_ plan: CompanionAudio.Plan?) {
        guard !isStopped else { return }
        guard let plan else {
            fail(UserFacingError.message(for: CompanionAudioError.noInput))
            return
        }
        cancelsEcho = plan == .voiceProcessing
        // Whatever was queued or paused went with the old graph. A turn in
        // progress is the turn taker's, which carries on across the rebuild.
        talkOverPending = false
        resumedEarly = false
        resumeAudio.removeAll()
        pendingSaid.removeAll()
        refreshPhase()
    }

    // MARK: - Connection

    /// A token for this connection, and the socket opened with it.
    private nonisolated static func open(client: CompanionTokenClient, handle: String?) async throws -> LiveSocket {
        let grant = try await client.grant(handle: handle, voice: voice)
        guard let url = LiveWire.url(token: grant.token) else { throw LiveSocketError.badURL }
        let socket = LiveSocket(url: url)
        try await socket.open(setup: grant.setup, timeout: setupTimeout)
        return socket
    }

    /// The new connection goes live before the old one is closed, so a GoAway
    /// costs no more than the handover. Whatever the old one still owed —
    /// an answer, the close of an interrupted one — will not come.
    private func adopt(_ socket: LiveSocket, resuming: Bool, since: Date) {
        let previous = self.socket
        self.socket = socket
        uplink.replace(socket)
        previous?.close()
        listen(to: socket)
        reconnectAttempts = 0
        serverTurnOpen = false
        interruptedTurnPending = false
        // The new connection has not been told what is on screen.
        lastVisibleListText = nil
        settleLostTurn()
        Diagnostics.record(resuming ? "companion.resumed" : "companion.connected", details: [
            ("ms", .ms(Self.ms(since: since))),
            ("sinceStart", .ms(Self.ms(since: startedAt))),
        ])
    }

    /// A turn the user finished on the old connection has no answer coming:
    /// nothing waits for it, and a voice paused for it goes on. A turn still
    /// being spoken carries over (`LiveUplink.replace`) and stays open.
    private func settleLostTurn() {
        cancelNoWordsGrace()
        guard !userSpeaking, reply == .awaitingWords else { return }
        reply = .open
        heldAudio.removeAll()
        heldFrames = 0
        prunePendingSaid()
        if talkOverPending { resumePausedVoice() }
    }

    private func reconnect() {
        guard !isStopped, !isReconnecting else { return }
        isReconnecting = true
        refreshPhase()
        Task { [weak self] in
            guard let self else { return }
            await self.reconnectLoop()
            self.isReconnecting = false
            self.handOverBy = nil
            self.refreshPhase()
            self.trySendStep()
        }
    }

    private func reconnectLoop() async {
        while !isStopped {
            // After a GoAway the old connection carries on until a quiet
            // moment; the new one is opened only then, with the handle from
            // that moment, so it remembers everything said meanwhile.
            await waitForQuietHandOver()
            let started = Date()
            do {
                let socket = try await Self.open(client: tokenClient, handle: resumeHandle)
                guard !isStopped else {
                    socket.close()
                    return
                }
                adopt(socket, resuming: resumeHandle != nil, since: started)
                if let latestFrame { socket.send(LiveWire.video(jpeg: latestFrame)) }
                return
            } catch {
                guard !isStopped else { return }
                Diagnostics.record("companion.connectFailed", details: [
                    ("resuming", .flag(resumeHandle != nil)),
                    ("attempt", .count(reconnectAttempts)),
                    ("error", .code(DiagnosticErrorClass(error))),
                ])
                guard reconnectAttempts < Self.maxReconnectAttempts else {
                    fail(UserFacingError.message(for: error))
                    return
                }
                reconnectAttempts += 1
                try? await Task.sleep(nanoseconds: UInt64(reconnectAttempts) * 1_000_000_000)
            }
        }
    }

    /// After a GoAway the old connection still works for a few seconds: the
    /// switch waits until nobody is mid-turn and nothing is owed, so a
    /// question is not split across two connections (unless time runs out).
    private func waitForQuietHandOver() async {
        // Opening the new connection takes about two seconds of the window.
        guard let handOverBy, socket != nil else { return }
        let deadline = handOverBy.addingTimeInterval(-2.5)
        // The old connection closing early ends the wait: there is nothing
        // left to finish on it.
        while Date() < deadline, !isStopped, socket != nil {
            if !userSpeaking, looks.isEmpty, !serverTurnOpen, reply == .open, !voiceAudible { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        Diagnostics.record("companion.handOverForced")
    }

    /// Names the app in front, shows the screen, then says hello (R18 決定3).
    private func greet(on socket: LiveSocket) async {
        let identity = await identityTask?.value
        if let appName = identity?.appName ?? targetApp?.localizedName {
            socket.send(LiveWire.note(CompanionGreeting.frontAppNote(
                appName: appName,
                windowTitle: identity?.windowTitle,
                host: identity?.host
            )))
        }
        if let latestFrame { socket.send(LiveWire.video(jpeg: latestFrame)) }
        // The greeting answers this turn, not one of the user's: it waits for
        // no words — unless the user is already talking to this connection.
        if !(userSpeaking && lastStartDelivered) { reply = .open }
        trace?.record("greeting")
        socket.send(LiveWire.turn(CompanionGreeting.start))
        serverTurnOpen = true
        turnEndedAt = Date()
        replyMeasured = false
        greetingPending = true
    }

    private func listen(to socket: LiveSocket) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            var failure: Error?
            do {
                for try await events in socket.events() {
                    guard let self, self.socket === socket else { return }
                    for event in events { self.handle(event) }
                }
            } catch {
                failure = error
            }
            self?.closed(socket, failure: failure)
        }
    }

    private func closed(_ socket: LiveSocket, failure: Error?) {
        guard socket === self.socket, !isStopped else { return }
        Diagnostics.record("companion.closed", details: [
            ("code", .count(socket.closeCode)),
            ("transport", .flag(failure != nil)),
            ("sinceStart", .ms(Self.ms(since: startedAt))),
        ])
        uplink.replace(nil)
        self.socket = nil
        serverTurnOpen = false
        interruptedTurnPending = false
        handOverBy = nil
        reconnect()
    }

    // MARK: - Server events

    private func handle(_ event: LiveEvent) {
        switch event {
        case .setupComplete:
            break
        case .interrupted:
            trace?.record("interrupted")
            interrupted()
        case .audio(let pcm):
            receive(pcm)
        case .heard(let text):
            trace?.record("user", ["text": text])
            heard(text)
        case .said(let text):
            trace?.record("companion", ["text": text])
            said(text)
        case .turnComplete:
            trace?.record("turnComplete")
            turnComplete()
        case .toolCall(let call):
            look(call)
        case .toolCallCancellation(let ids):
            Diagnostics.record("companion.toolCancelled", details: [("count", .count(ids.count))])
            for id in ids {
                looks[id]?.cancel()
                looks[id] = nil
            }
            refreshPhase()
        case .goAway(let timeLeftMs):
            Diagnostics.record("companion.goAway", details: [
                ("timeLeft", .ms(timeLeftMs ?? -1)),
                ("sinceStart", .ms(Self.ms(since: startedAt))),
            ])
            let window = timeLeftMs.map { max(0, Double($0) / 1_000 - 1.5) } ?? Self.defaultHandOverWindow
            handOverBy = Date().addingTimeInterval(window)
            reconnect()
        case .resumption(let handle):
            resumeHandle = handle
        case .usage(let usage):
            Diagnostics.record("companion.usage", details: [
                ("prompt", .count(usage.prompt)),
                ("response", .count(usage.response)),
                ("total", .count(usage.total)),
                ("thoughts", .count(usage.thoughts)),
                ("audioIn", .count(usage.promptAudio)),
                ("imageIn", .count(usage.promptImage)),
                ("textIn", .count(usage.promptText)),
            ])
        }
    }

    private func receive(_ pcm: Data) {
        if greetingPending { greetingSpoke = true }
        guard reply == .open, !userSpeaking else {
            // The first of an answer to a turn that has no words yet: the
            // words usually came first (measured), so this is likely a noise.
            if reply == .awaitingWords, !userSpeaking, heldAudio.isEmpty { startNoWordsGrace() }
            heldAudio.append(pcm)
            heldFrames += pcm.count / 2
            return
        }
        play(pcm)
    }

    private func play(_ pcm: Data) {
        if !replyMeasured, let since = turnEndedAt {
            Diagnostics.record("companion.replied", details: [
                ("ms", .ms(Self.ms(since: since))),
                ("greeting", .flag(greetingPending)),
            ])
            replyMeasured = true
        }
        audio.play(pcm16: pcm)
    }

    /// Words for the user's turn: what waited for them may play, and a voice
    /// paused for them is dropped — it was a person.
    private func heard(_ text: String) {
        transcript.append(text, from: .user)
        guard CompanionTranscript.hasWords(text) else { return }
        heardThisTurn = true
        appendLine(.user, text)
        if talkOverPending || resumedEarly { confirmTalkOver() }
        if !userSpeaking, reply == .awaitingWords {
            reply = .open
            cancelNoWordsGrace()
            releaseHeld()
        }
    }

    /// A person talked over the voice: what was left of it is dropped.
    private func confirmTalkOver() {
        let resumed = resumedEarly
        talkOverPending = false
        resumedEarly = false
        resumeAudio.removeAll()
        let before = audio.frameMark()
        audio.flush()
        let after = audio.frameMark()
        // The paused voice's words go with it; those of the answer still held
        // (queued past the paused voice) move to the new generation, to show
        // as it plays.
        pendingSaid = pendingSaid.compactMap { piece in
            guard piece.generation == before.generation, piece.frame > before.frames else { return nil }
            return (after.generation, piece.frame - before.frames, piece.text)
        }
        transcript.cut()
        Diagnostics.record("companion.talkOverConfirmed", details: [("afterResume", .flag(resumed))])
    }

    /// The voice paused for a "person" carries on where it stopped.
    private func resumePausedVoice() {
        talkOverPending = false
        audio.resumeVoice()
        let pieces = resumeAudio
        resumeAudio.removeAll()
        for pcm in pieces { play(pcm) }
    }

    private func said(_ text: String) {
        let mark = audio.frameMark()
        let frame = mark.frames + heldFrames
        // A piece that trails its audio, which has already been heard, is
        // shown at once; no later completion would show it.
        if heldFrames == 0, frame <= mark.played {
            transcript.append(text, from: .companion)
        } else {
            pendingSaid.append((mark.generation, frame, text))
        }
    }

    private func interrupted() {
        interruptedTurnPending = true
        if talkOverPending {
            // The user is talking over the paused voice. Whether it was a
            // person is not known yet; what had arrived of the answer is kept
            // in case it carries on.
            resumeAudio += heldAudio
            heldAudio.removeAll()
            heldFrames = 0
            Diagnostics.record("companion.interrupted", details: [("talkOver", .flag(true))])
            return
        }
        let wasAudible = voiceAudible
        audio.flush()
        heldAudio.removeAll()
        heldFrames = 0
        pendingSaid.removeAll()
        transcript.cut()
        Diagnostics.record("companion.interrupted", details: [
            ("talkOver", .flag(false)),
            ("playing", .flag(wasAudible)),
        ])
    }

    private func turnComplete() {
        // Whatever the server owed has come (or was cut off).
        serverTurnOpen = false
        turnWatchdog?.cancel()
        turnWatchdog = nil
        let step = stepInFlight
        stepInFlight = nil
        if interruptedTurnPending {
            // The close of the answer that was cut off, not of the user's
            // turn. A step in it was not heard; the guide may read it again.
            interruptedTurnPending = false
            transcript.endTurn()
            trySendStep()
            return
        }
        if let step { stepHeard(step) }
        if greetingPending {
            greetingPending = false
            if !greetingSpoke, !greetingRetried, let socket {
                // A silent greeting (build 18 had one): asked once more.
                greetingRetried = true
                greetingPending = true
                Diagnostics.record("companion.greetingSilent")
                socket.send(LiveWire.turn(CompanionGreeting.start))
                serverTurnOpen = true
                return
            }
        }
        // The turn the user ended without words is over: its answer, if any,
        // is dropped, and a voice paused for it carries on.
        if !userSpeaking, reply == .awaitingWords, !heardThisTurn {
            reply = .open
            cancelNoWordsGrace()
            let dropped = heldAudio.count
            heldAudio.removeAll()
            heldFrames = 0
            prunePendingSaid()
            if talkOverPending { resumePausedVoice() }
            resumedEarly = false
            Diagnostics.record("companion.noWords", details: [("droppedChunks", .count(dropped))])
        }
        transcript.endTurn()
        trySendStep()
    }

    /// The answer to a turn without words has started to arrive. A voice
    /// paused for that turn does not wait for the whole unheard answer to run
    /// its real-time course: after a short grace it carries on. Words arriving
    /// later still win (`heard` drops it again).
    private func startNoWordsGrace() {
        guard talkOverPending, noWordsTask == nil else { return }
        noWordsTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noWordsGrace)
            guard let self, !Task.isCancelled else { return }
            self.noWordsTask = nil
            guard self.talkOverPending, !self.heardThisTurn, !self.userSpeaking,
                  self.reply == .awaitingWords else { return }
            self.resumePausedVoice()
            self.resumedEarly = true
            Diagnostics.record("companion.talkOverResumed")
            self.refreshPhase()
        }
    }

    private func cancelNoWordsGrace() {
        noWordsTask?.cancel()
        noWordsTask = nil
    }

    // MARK: - The user's turns

    private func userTurn(_ turn: CompanionAudio.UserTurn) {
        switch turn {
        case .started(let overVoice):
            trace?.record("userStarted", ["overVoice": overVoice])
            userSpeaking = true
            heardThisTurn = false
            turnCursor = NSEvent.mouseLocation
            guard lastStartDelivered else {
                // No connection heard this start, so no answer will come for
                // it; nothing is held for one, and a voice paused for it goes on.
                if overVoice { audio.resumeVoice() }
                Diagnostics.record("companion.turnUndelivered")
                refreshPhase()
                return
            }
            // A step read for the old instruction is stale now, and so is the
            // frame it drew.
            if pendingStep != nil {
                pendingStep = nil
                eye.clearMarks()
            }
            // Whatever waited for the previous turn is stale now.
            cancelNoWordsGrace()
            heldAudio.removeAll()
            heldFrames = 0
            prunePendingSaid()
            reply = .awaitingWords
            if overVoice { talkOverPending = true }
            transcript.endTurn()
            refreshVisibleList(force: false)
        case .stopped:
            trace?.record("userStopped")
            userSpeaking = false
            turnEndedAt = Date()
            replyMeasured = false
            if lastStartDelivered, !lastEndDelivered, reply == .awaitingWords, !heardThisTurn {
                // The connection that heard the start is gone and no other
                // heard the end: no answer is coming for this turn.
                settleLostTurn()
                Diagnostics.record("companion.turnLost")
            } else if reply == .open {
                // Held only because the user was talking (a greeting).
                releaseHeld()
            } else if heardThisTurn {
                reply = .open
                releaseHeld()
            } else if !heldAudio.isEmpty {
                startNoWordsGrace()
            }
        }
        refreshPhase()
    }

    private func releaseHeld() {
        let pieces = heldAudio
        heldAudio.removeAll()
        heldFrames = 0
        for pcm in pieces { play(pcm) }
    }

    private func speakingChanged(_ isSpeaking: Bool) {
        voiceAudible = isSpeaking
        refreshPhase()
        if !isSpeaking { trySendStep() }
    }

    // MARK: - The eye

    private func look(_ call: LiveToolCall) {
        guard call.name == Self.lookTool else {
            socket?.send(LiveWire.toolResponse(id: call.id, name: call.name, output: "そのような機能はありません。"))
            return
        }
        Diagnostics.record("companion.toolCall", details: [
            ("nextStep", .flag(call.nextStep)),
            ("cursor", .flag(call.pointsAtCursor)),
            ("heard", .flag(heardThisTurn)),
        ])
        trace?.record("look", [
            "question": call.question ?? "",
            "goal": call.goal ?? "",
            "nextStep": call.nextStep,
            "cursor": call.pointsAtCursor,
        ])
        // The model acted on the user's turn: that is as good as words. A
        // voice paused for it was paused for a person, and its answer must not
        // be dropped as noise even if the transcript never comes.
        if (talkOverPending || resumedEarly), !userSpeaking { confirmTalkOver() }
        heardThisTurn = true
        if !userSpeaking, reply == .awaitingWords {
            reply = .open
            cancelNoWordsGrace()
            releaseHeld()
        }
        // The model is looking for itself: a step the guide is reading now
        // would say the same thing twice. The guidance goes on, and if this
        // look turns out to answer something else, the step is read again.
        let droppedStep = pendingStep != nil || guide.cancelRunningStep()
        pendingStep = nil
        // An answer still waiting was asked for before this question.
        if pendingAnswer != nil {
            pendingAnswer = nil
            trace?.record("answerDropped", ["reason": "newerLook"])
            Diagnostics.record("companion.answerDropped", details: [("superseded", .flag(true))])
        }
        // Answered at once: 3.1 Flash Live says nothing until a tool response,
        // and the owner wants the companion to keep talking while 田中さん
        // reads. The answer goes to the voice later, as a turn (`answerLater`).
        socket?.send(LiveWire.toolResponse(id: call.id, name: call.name, output: Self.lookAcknowledgement))
        serverTurnOpen = true
        if let goal = call.goal, !goal.isEmpty { currentGoal = goal }
        let request = CompanionEye.Request(
            question: call.question ?? "",
            goal: currentGoal,
            nextStep: call.nextStep,
            pointsAtCursor: call.pointsAtCursor,
            history: lines,
            previousInstruction: lastInstruction,
            displayID: displayID,
            cursor: turnCursor
        )
        looks[call.id] = Task { [weak self] in
            guard let self else { return }
            let reading = await self.eye.look(request, adopting: nil)
            guard !Task.isCancelled, self.looks[call.id] != nil else { return }
            self.looks[call.id] = nil
            // With no goal ever stated, the question is the best there is.
            self.answerLater(reading, goal: request.goal ?? call.question)
            let gaveStep = !reading.superseded && (reading.look.kind == .nextStep || reading.look.kind == .done)
            if droppedStep, !gaveStep { self.guide.readNow() }
            self.refreshPhase()
        }
        refreshPhase()
    }

    /// 田中さん has read the screen. The look was answered at once, so this
    /// goes to the voice as a turn of its own at the next quiet moment — on
    /// whichever connection is open by then.
    private func answerLater(_ reading: CompanionEye.Reading, goal: String?) {
        trace?.record("told", ["output": reading.look.toolOutput, "superseded": reading.superseded])
        // A newer look is the one being answered: an answer to the older
        // question would contradict it (3.1 relayed such stale answers 6 of 6).
        guard !reading.superseded else {
            Diagnostics.record("companion.answerDropped", details: [("superseded", .flag(true))])
            return
        }
        pendingAnswer = (reading.look, goal)
        trySendStep()
    }

    /// What a look told the user. A step becomes the instruction the next one
    /// follows and (re)starts the guidance toward its goal; the goal reached
    /// ends it. Anything else — an answer to a side question, a failure —
    /// leaves the guidance as it was.
    private func follow(_ look: CompanionEye.Look, goal: String?) {
        guard look.kind != .failure else { return }
        skillName = look.skillName
        if !look.message.isEmpty { appendLine(.companion, look.message) }
        switch look.kind {
        case .nextStep:
            guard !look.message.isEmpty else { return }
            lastInstruction = look.message
            if let goal, !goal.isEmpty {
                guide.begin(
                    goal: goal,
                    previousInstruction: look.message,
                    history: { [weak self] in self?.lines ?? [] },
                    displayID: displayID,
                    excludedFrame: { [weak self] in self?.panelFrame() }
                )
            }
        case .done:
            guide.stop()
            currentGoal = nil
        default:
            break
        }
    }

    /// The user acted and the screen settled: the next step waits for a quiet
    /// moment, then goes to the model as a turn of its own.
    private func stepRead(_ look: CompanionEye.Look) {
        guard look.kind != .failure else { return }
        skillName = look.skillName
        pendingStep = look
        trySendStep()
    }

    /// 田中さん's answer or the guide's next step, whichever waits, goes to
    /// the voice as a turn — the answer first, since the user asked for it.
    private func trySendStep() {
        guard pendingAnswer != nil || pendingStep != nil, let socket, !isReconnecting,
              !userSpeaking, !voiceAudible, !talkOverPending, !serverTurnOpen,
              reply == .open, looks.isEmpty
        else { return }
        // A turn interrupts whatever the model is generating; the guards above
        // make sure it owes nothing.
        if let answer = pendingAnswer {
            pendingAnswer = nil
            trace?.record("answer", ["text": answer.look.toolOutput])
            socket.send(LiveWire.turn("（田中さんから）\n" + answer.look.toolOutput))
            openTurn()
            Diagnostics.record("companion.answerSpoken", details: [("kind", .code(answer.look.kind))])
            follow(answer.look, goal: answer.goal)
            return
        }
        guard let step = pendingStep else { return }
        pendingStep = nil
        trace?.record("step", ["text": step.toolOutput])
        socket.send(LiveWire.turn("（次の一歩）\n" + step.toolOutput))
        openTurn()
        stepInFlight = step
        if step.kind == .done { guide.stop() }
        Diagnostics.record("companion.stepSpoken", details: [("done", .flag(step.kind == .done))])
    }

    /// A turn went to the model, which now owes an answer. One it answers
    /// with silence never completes (probed on 3.1), and every later answer
    /// and step would wait behind it: the floor comes back after a while.
    private func openTurn() {
        serverTurnOpen = true
        turnEndedAt = Date()
        replyMeasured = false
        turnWatchdog?.cancel()
        turnWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.silentTurnLimit)
            guard let self, !Task.isCancelled, !self.isStopped,
                  self.serverTurnOpen, !self.replyMeasured, !self.voiceAudible
            else { return }
            self.serverTurnOpen = false
            self.stepInFlight = nil
            self.trace?.record("turnSilent")
            Diagnostics.record("companion.turnSilent")
            self.trySendStep()
            self.refreshPhase()
        }
    }

    /// The step's turn completed: the user heard it, and it is the
    /// instruction the next act is judged against.
    private func stepHeard(_ step: CompanionEye.Look) {
        guard !step.message.isEmpty else { return }
        appendLine(.companion, step.message)
        guard step.kind == .nextStep else { return }
        lastInstruction = step.message
        guide.update(previousInstruction: step.message)
    }

    /// An AX list of what is on screen, as context the model does not answer
    /// (notes interrupt nothing). Taken when the user starts talking, so it is
    /// usually there before their turn ends; skipped while the screen and the
    /// app in front are what the last list described (requirements R9).
    private func refreshVisibleList(force: Bool) {
        guard visibleListTask == nil else { return }
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let unchanged = framesSeen == lastVisibleListFrames && pid == lastVisibleListPID
        guard force || !unchanged || Date().timeIntervalSince(lastVisibleListAt) >= Self.visibleListStale else {
            return
        }
        lastVisibleListAt = Date()
        lastVisibleListFrames = framesSeen
        lastVisibleListPID = pid
        visibleListTask = Task { [weak self] in
            guard let self else { return }
            let list = await self.eye.visibleList(displayID: self.displayID)
            self.visibleListTask = nil
            guard !Task.isCancelled, !self.isStopped, let list else { return }
            // The same lines again add nothing but tokens.
            let body = list.split(separator: "\n").dropFirst().joined(separator: "\n")
            guard body != self.lastVisibleListText else { return }
            self.lastVisibleListText = body
            self.trace?.record("note", ["text": list])
            self.socket?.send(LiveWire.note(list))
        }
    }

    private func appendLine(_ role: CompanionEye.Line.Role, _ text: String) {
        if role == .user, let last = lines.last, last.role == .user {
            lines[lines.count - 1] = CompanionEye.Line(role: .user, text: last.text + text)
        } else {
            lines.append(CompanionEye.Line(role: role, text: text))
        }
        if lines.count > 12 { lines.removeFirst(lines.count - 12) }
    }

    // MARK: - Transcript in step with the voice

    private func revealSaid(generation: Int, played: Int) {
        var shown = ""
        pendingSaid.removeAll { piece in
            if piece.generation < generation { return true }
            guard piece.generation == generation, piece.frame <= played else { return false }
            shown += piece.text
            return true
        }
        if !shown.isEmpty { transcript.append(shown, from: .companion) }
    }

    /// Drops pieces of answers that will never be played.
    private func prunePendingSaid() {
        let mark = audio.frameMark()
        pendingSaid.removeAll { $0.generation != mark.generation || $0.frame > mark.frames }
    }

    // MARK: - State

    private func refreshPhase() {
        if case .failed = phase { return }
        if isStopped { return }
        if isReconnecting, socket == nil {
            // A GoAway handover keeps the old connection working meanwhile;
            // only a lost one is "reconnecting".
            phase = .reconnecting
        } else if socket == nil {
            phase = .connecting
        } else if userSpeaking {
            phase = .hearing
        } else if voiceAudible, !talkOverPending {
            phase = .speaking
        } else if !looks.isEmpty || guideReading {
            phase = .looking
        } else {
            phase = .listening
        }
    }

    private func publishInputLevel(_ rms: Float) {
        // 「これ」 is where the pointer was while the user was talking.
        if userSpeaking, rms > 0.003 { turnCursor = NSEvent.mouseLocation }
        let now = Date()
        guard now.timeIntervalSince(lastLevelPublish) >= Self.levelInterval else { return }
        lastLevelPublish = now
        inputLevel = isMuted ? 0 : min(1, rms * 12)
    }

    private func fail(_ message: String) {
        tearDown()
        phase = .failed(message)
        Diagnostics.record("companion.ended", details: [
            ("duration", .ms(Self.ms(since: startedAt))),
            ("frames", .count(framesSeen)),
        ])
    }

    private func tearDown() {
        isStopped = true
        turnWatchdog?.cancel()
        turnWatchdog = nil
        trace?.record("ended")
        trace?.close()
        receiveTask?.cancel()
        receiveTask = nil
        uplink.replace(nil)
        socket?.close()
        socket = nil
        cancelNoWordsGrace()
        audio.stop()
        screen.stop()
        identityTask?.cancel()
        visibleListTask?.cancel()
        for task in looks.values { task.cancel() }
        looks.removeAll()
        guide.stop()
        eye.clearMarks()
        eye.tearDown()
    }

    private static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }
}
