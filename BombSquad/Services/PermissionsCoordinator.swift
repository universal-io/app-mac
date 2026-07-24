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

        /// Step-by-step guidance for the case the OS dialog does not appear
        /// (screen recording after the one-time prompt). Nil where the system
        /// dialog is the normal path.
        var manualSetupSteps: String? {
            switch self {
            case .screenRecording:
                return "「許可」を押すと設定が開きます。"
                    + "システム設定 › プライバシーとセキュリティ › 画面収録とシステムオーディオ録音 で "
                    + "Universal I/O をオンにし、アプリを一度終了してから開き直してください。"
                    + "一覧にあるのにオンにできない時は、一度 OFF→ON（または − で削除して + で追加）します。"
            case .accessibility, .microphone:
                return nil
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
    /// Kinds whose "許可" press just launched System Settings, so the row can
    /// show an immediate "開いています…" reaction instead of looking dead for
    /// the second or two before Settings comes forward.
    @Published private(set) var openingSettings: Set<Kind> = []
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
            // The OS dialog appears only once per app, so pressing 許可 must not
            // depend on it. Fire the prompt (a genuine first-timer can grant in
            // one click) AND deterministically open the exact Settings pane on
            // every press, with immediate on-screen feedback. A normal user
            // must never be left hunting for where "画面収録" lives.
            _ = ScreenCapturePermission.request()
            openSettingsWithFeedback(kind) { ScreenCapturePermission.openSettings() }
        case .microphone:
            if MicrophonePermission.isDenied {
                openSettingsWithFeedback(kind) { MicrophonePermission.openSettings() }
            } else {
                MicrophonePermission.request { [weak self] _ in self?.refresh() }
            }
        }
    }

    /// Marks the row as "opening Settings…" so the press has an immediate
    /// reaction, then launches Settings on the next tick (so the feedback
    /// renders before the blocking launch call). The flag clears itself.
    private func openSettingsWithFeedback(_ kind: Kind, _ open: @escaping () -> Void) {
        openingSettings.insert(kind)
        DispatchQueue.main.async { open() }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self?.openingSettings.remove(kind)
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
