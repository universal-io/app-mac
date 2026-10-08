import AppKit

/// R18: one conversation with the companion — the connection, its ears and
/// mouth, what it sees — from the double-tap that starts it to the one that
/// ends it.
///
/// Lives outside `AppMode` on purpose (master plan R18 決定5): the user keeps
/// working in other apps the whole time, and Vision's `close()` stops
/// recording as a side effect.
///
/// V1 is the voice only. The model calls `look_closely` before naming a place
/// on screen, and until the eye exists (V2) it is told so.
@MainActor
final class CompanionSession: ObservableObject {
    enum Phase: Equatable {
        case connecting
        case listening
        case speaking
        case reconnecting
        case failed(String)
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var transcript = CompanionTranscript()
    @Published private(set) var isMuted = false
    /// The microphone, 0...1, for the window's meter.
    @Published private(set) var inputLevel: Float = 0
    /// False when the audio could only start without echo cancellation; the
    /// companion would then hear itself from the speakers.
    @Published private(set) var cancelsEcho = true

    /// The voice of the POC sessions the owner rated well (2026-10-08 logs).
    static let voice = "Zephyr"
    private static let setupTimeout: TimeInterval = 10
    private static let maxReconnectAttempts = 3
    private static let levelInterval: TimeInterval = 1.0 / 15

    private let tokenClient: CompanionTokenClient
    private let targetApp: NSRunningApplication?
    private let audio = CompanionAudio()
    private let screen = CompanionScreenFeed()
    private let uplink = LiveUplink()
    private var socket: LiveSocket?
    private var receiveTask: Task<Void, Never>?
    private var identityTask: Task<VisionObservationCaptureService.TargetIdentity?, Never>?
    private var resumeHandle: String?
    /// The last frame the feed produced, sent again on every (re)connect: the
    /// feed only sends changes, and a still screen would otherwise never reach
    /// a fresh connection.
    private var latestFrame: Data?
    private var framesSeen = 0
    private var isStopped = false
    private var isReconnecting = false
    private var reconnectAttempts = 0
    private var speaking = false
    private let startedAt = Date()
    /// Since when the user's last words have been waiting for a voice. Measured
    /// from the last transcript piece, which trails the end of speech a little.
    private var awaitingReplySince: Date?
    private var greetingPending = false
    private var lastLevelPublish = Date.distantPast

    init?(targetApp: NSRunningApplication?) {
        guard let tokenClient = CompanionTokenClient.make() else { return nil }
        self.tokenClient = tokenClient
        self.targetApp = targetApp
    }

    var statusText: String {
        switch phase {
        case .connecting: return "つないでいます…"
        case .listening:
            if isMuted { return "ミュート中" }
            return cancelsEcho ? "聞いています" : "聞いています・ヘッドホン推奨"
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
        // The display showing the app the user is in, resolved while that app
        // is still in front.
        let displayID = ActiveDisplay.displayID(of: ActiveDisplay.pin(to: targetApp))
        identityTask = VisionObservationCaptureService.identityTask(
            preferredPID: targetApp?.processIdentifier
        )
        wire()
        Task { [weak self] in
            await self?.startScreen(displayID: displayID)
        }
        Task { [weak self] in
            guard let self, await self.prepareMicrophone(), self.startAudio() else { return }
            await self.connect(resuming: false)
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
        if isMuted { uplink.send(LiveWire.audioStreamEnd) }
        Diagnostics.record("companion.muted", details: [("on", .flag(isMuted))])
    }

    // MARK: - Start

    private func wire() {
        audio.onCapture = { [uplink] pcm in
            uplink.send(LiveWire.audio(pcm))
        }
        audio.onSpeakingChanged = { [weak self] isSpeaking in
            MainActor.assumeIsolated { self?.speakingChanged(isSpeaking) }
        }
        audio.onInputLevel = { [weak self] level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.publishInputLevel(level) }
            }
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
    }

    private func startScreen(displayID: CGDirectDisplayID?) async {
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
            cancelsEcho = audio.plan?.cancelsEcho ?? false
            return true
        } catch {
            Diagnostics.record("companion.audioFailed", details: [
                ("error", .code(DiagnosticErrorClass(error))),
            ])
            fail(UserFacingError.message(for: error))
            return false
        }
    }

    // MARK: - Connection

    private func connect(resuming: Bool) async {
        let started = Date()
        do {
            let grant = try await tokenClient.grant(
                handle: resuming ? resumeHandle : nil,
                voice: Self.voice
            )
            guard let url = LiveWire.url(token: grant.token) else { throw LiveSocketError.badURL }
            let socket = LiveSocket(url: url)
            try await socket.open(setup: grant.setup, timeout: Self.setupTimeout)
            guard !isStopped else {
                socket.close()
                return
            }
            // The new connection goes live before the old one is closed, so a
            // GoAway costs no more than the handover.
            let previous = self.socket
            self.socket = socket
            uplink.replace(socket)
            previous?.close()
            listen(to: socket)
            reconnectAttempts = 0
            Diagnostics.record(resuming ? "companion.resumed" : "companion.connected", details: [
                ("ms", .ms(Self.ms(since: started))),
                ("sinceStart", .ms(Self.ms(since: startedAt))),
            ])
            if resuming {
                if let latestFrame { socket.send(LiveWire.video(jpeg: latestFrame)) }
            } else {
                await greet(on: socket)
            }
            phase = speaking ? .speaking : .listening
        } catch {
            guard !isStopped else { return }
            Diagnostics.record("companion.connectFailed", details: [
                ("resuming", .flag(resuming)),
                ("attempt", .count(reconnectAttempts)),
                ("error", .code(DiagnosticErrorClass(error))),
            ])
            if resuming, reconnectAttempts < Self.maxReconnectAttempts {
                reconnectAttempts += 1
                try? await Task.sleep(nanoseconds: UInt64(reconnectAttempts) * 1_000_000_000)
                await connect(resuming: true)
            } else {
                fail(UserFacingError.message(for: error))
            }
        }
    }

    /// Names the app in front, shows the screen, then says hello (R18 決定3).
    /// The identity read began with the session and is bounded at two
    /// seconds, so by now it has usually finished; nothing slower is waited for.
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
        socket.send(LiveWire.turn(CompanionGreeting.start))
        awaitingReplySince = Date()
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

    private func handle(_ event: LiveEvent) {
        switch event {
        case .setupComplete:
            break
        case .interrupted:
            audio.flush()
            Diagnostics.record("companion.interrupted")
        case .audio(let pcm):
            if let since = awaitingReplySince {
                Diagnostics.record("companion.replied", details: [
                    ("ms", .ms(Self.ms(since: since))),
                    ("greeting", .flag(greetingPending)),
                ])
                awaitingReplySince = nil
                greetingPending = false
            }
            audio.play(pcm16: pcm)
        case .heard(let text):
            transcript.append(text, from: .user)
            awaitingReplySince = Date()
        case .said(let text):
            transcript.append(text, from: .companion)
        case .turnComplete:
            transcript.endTurn()
        case .toolCall(let call):
            answerWithoutEye(call)
        case .toolCallCancellation(let ids):
            Diagnostics.record("companion.toolCancelled", details: [("count", .count(ids.count))])
        case .goAway(let timeLeftMs):
            Diagnostics.record("companion.goAway", details: [
                ("timeLeft", .ms(timeLeftMs ?? -1)),
                ("sinceStart", .ms(Self.ms(since: startedAt))),
            ])
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

    /// V1 has no eye (R18 V2). The model asks before naming a place on screen;
    /// it is told plainly that it cannot, so it says so instead of guessing.
    private func answerWithoutEye(_ call: LiveToolCall) {
        Diagnostics.record("companion.toolCall")
        socket?.send(LiveWire.toolResponse(
            id: call.id,
            name: call.name,
            output: "精読はまだ使えません。画面の具体的な場所やボタンは案内できないと、短く伝えてください。"
        ))
    }

    private func reconnect() {
        guard !isStopped, !isReconnecting else { return }
        isReconnecting = true
        phase = .reconnecting
        Task { [weak self] in
            guard let self else { return }
            await self.connect(resuming: self.resumeHandle != nil)
            self.isReconnecting = false
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
        reconnect()
    }

    // MARK: - State

    private func speakingChanged(_ isSpeaking: Bool) {
        speaking = isSpeaking
        guard phase == .listening || phase == .speaking else { return }
        phase = isSpeaking ? .speaking : .listening
    }

    private func publishInputLevel(_ rms: Float) {
        let now = Date()
        guard now.timeIntervalSince(lastLevelPublish) >= Self.levelInterval else { return }
        lastLevelPublish = now
        inputLevel = isMuted ? 0 : min(1, rms * 12)
    }

    private func fail(_ message: String) {
        tearDown()
        phase = .failed(message)
    }

    private func tearDown() {
        isStopped = true
        receiveTask?.cancel()
        receiveTask = nil
        uplink.replace(nil)
        socket?.close()
        socket = nil
        audio.stop()
        screen.stop()
        identityTask?.cancel()
    }

    private static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1_000)
    }
}
