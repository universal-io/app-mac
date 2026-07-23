import AppKit
import SwiftUI

/// Single source of truth for the three system permissions the app needs, and
/// the one place that requests them. Prior to this, Accessibility / Microphone
/// were requested ad hoc at launch while Screen Recording was only requested
/// the first time Vision ran — so a menu-bar app (no front window) scattered
/// system dialogs across displays, and a TCC reset left Screen Recording absent
/// from the settings list entirely. The setup window observes this coordinator
/// and drives each grant deliberately from a focused, front-most window.
@MainActor
final class PermissionsCoordinator: ObservableObject {
    enum Kind: CaseIterable, Identifiable {
        case accessibility
        case screenRecording
        case microphone

        var id: Self { self }

        var title: String {
            switch self {
            case .accessibility: return "アクセシビリティ"
            case .screenRecording: return "画面収録"
            case .microphone: return "マイク"
            }
        }

        var reason: String {
            switch self {
            case .accessibility:
                // The gesture is user-configurable, so keep this general and
                // example-like rather than naming a specific key.
                return "テキストの自動入力や、ジェスチャなどの操作の検出に使用します。"
            case .screenRecording:
                return "画面の内容を読み取るために使用します。この許可の反映には、アプリの再起動が一度だけ必要です。"
            case .microphone:
                return "音声入力に使用します。"
            }
        }

        var systemImage: String {
            switch self {
            case .accessibility: return "hand.point.up.left"
            case .screenRecording: return "rectangle.dashed"
            case .microphone: return "mic"
            }
        }
    }

    @Published private(set) var granted: [Kind: Bool] = [:]

    /// Kinds where the user pressed "許可" but the OS still reports no grant a few
    /// seconds later. This is the signature-mismatch case: an entry left in
    /// System Settings by a differently-signed build (e.g. the old shared dev id,
    /// or a re-signed update) shows its toggle ON, yet AXIsProcessTrusted /
    /// CGPreflightScreenCaptureAccess validate against THIS app's signature and
    /// return false — so no fresh dialog appears and the row looks stuck. The
    /// setup UI surfaces a hint (toggle OFF→ON / relaunch) only for these.
    @Published private(set) var stalled: Set<Kind> = []
    private var requestedAt: [Kind: Date] = [:]
    private let stallThreshold: TimeInterval = 3

    /// Fires once, when the microphone transitions to granted (so audio can be
    /// warmed up off the hot path only after access exists).
    var onMicrophoneGranted: (() -> Void)?

    private var pollTimer: Timer?
    private var sawMicrophoneGranted = false

    // Every stored property has a default, so construction touches no isolated
    // state — lets AppDelegate (nonisolated) hold this without a MainActor hop.
    nonisolated init() {}

    func isGranted(_ kind: Kind) -> Bool { granted[kind] ?? false }

    var needsAny: Bool { Kind.allCases.contains { !isGranted($0) } }
    var allGranted: Bool { !needsAny }

    /// Re-reads live status. Accessibility and Screen Recording expose no
    /// grant/deny callback, so the setup window polls this while open to catch
    /// a toggle the user flips in System Settings.
    func refresh() {
        granted[.accessibility] = AccessibilityPermission.isTrusted
        granted[.screenRecording] = ScreenCapturePermission.isGranted
        let mic = MicrophonePermission.isGranted
        granted[.microphone] = mic
        if mic && !sawMicrophoneGranted {
            sawMicrophoneGranted = true
            onMicrophoneGranted?()
        }

        // A grant that "takes" clears its request; one that stays false past the
        // threshold is flagged stalled so the row can explain why.
        let now = Date()
        for kind in Kind.allCases {
            if isGranted(kind) {
                requestedAt[kind] = nil
                stalled.remove(kind)
            } else if let at = requestedAt[kind], now.timeIntervalSince(at) > stallThreshold {
                stalled.insert(kind)
            }
        }
    }

    func startMonitoring() {
        refresh()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Requests one permission via the OS's own flow — and nothing more.
    ///
    /// Accessibility and Screen Recording surface a system dialog ("… wants to
    /// control / record … → Open System Settings | Deny"). We must NOT also
    /// open System Settings ourselves: doing both moved focus to Settings on
    /// another display (so the dialog appeared there) and left the dialog
    /// unhandled, so they piled up. Keeping focus on our key window and firing
    /// only the system prompt puts the dialog on our screen and lets its own
    /// button consume it. Microphone completes inline (no Settings trip) unless
    /// already denied, where Settings is the only recourse.
    func request(_ kind: Kind) {
        requestedAt[kind] = Date()
        stalled.remove(kind)
        NSApp.activate(ignoringOtherApps: true)
        switch kind {
        case .accessibility:
            AccessibilityPermission.prompt()
        case .screenRecording:
            _ = ScreenCapturePermission.request()
        case .microphone:
            if MicrophonePermission.isDenied {
                MicrophonePermission.openSettings()
            } else {
                MicrophonePermission.request { [weak self] _ in self?.refresh() }
            }
        }
    }

    /// Fallback for the denied case, where the system prompt no longer appears:
    /// jump straight to the relevant Settings pane. Exposed as a secondary
    /// action so the primary "許可" button never opens Settings itself.
    func openSettings(_ kind: Kind) {
        switch kind {
        case .accessibility: AccessibilityPermission.openSettings()
        case .screenRecording: ScreenCapturePermission.openSettings()
        case .microphone: MicrophonePermission.openSettings()
        }
    }
}
