import AppKit

/// The last resort, kept inside the app instead of inside a support reply.
///
/// R11 removes the ways a session could stall silently, but the 2026-08-03
/// failure also proved something about recovery: the summon that failed had
/// built a brand-new window and a brand-new hosting controller, so rebuilding
/// the panel is not a recovery path — the freshly built one is what failed.
/// Process restart was the only thing that worked
/// (docs/reliability-hardening-plan.md §1-b).
///
/// So it is offered as one menu command. Never automatically: an app that
/// restarts itself on a heuristic takes the user's session away on its own
/// judgement. The menu bar is the right home because the panel is precisely
/// what may be unresponsive when this is needed.
@MainActor
enum AppRestart {
    static func confirmAndRestart() {
        let alert = NSAlert()
        alert.messageText = "Universal I/Oを再起動しますか？"
        alert.informativeText = """
        パネルが反応しない時の回復手段です。保存済みの下書きとログイン状態はそのまま残ります。\
        表示中の画面の解説や会話は失われます。
        """
        alert.addButton(withTitle: "再起動")
        alert.addButton(withTitle: "キャンセル")
        alert.alertStyle = .warning

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            Diagnostics.record("app.restartCancelled")
            return
        }
        restart()
    }

    private static func restart() {
        Diagnostics.record("app.restarting")
        let configuration = NSWorkspace.OpenConfiguration()
        // Without this the workspace simply activates the copy that is already
        // running — which is the copy being replaced.
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                if let error {
                    Diagnostics.record("app.restartFailed", details: [
                        ("error", .code(DiagnosticErrorClass(error))),
                    ])
                    presentRestartFailure()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// A recovery action that fails without saying so would be worse than not
    /// offering one: the user would be left believing the app had restarted.
    private static func presentRestartFailure() {
        let alert = NSAlert()
        alert.messageText = "再起動できませんでした。"
        alert.informativeText =
            "Universal I/Oを手動で終了し、もう一度起動してください。"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
