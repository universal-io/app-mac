import AppKit
import SwiftUI

/// Universal I/O (I//O) — a semantic I/O layer between you and your apps.
/// Runs as a menu-bar (accessory) app: no window at launch, no Dock icon.
///
/// Two surfaces only:
/// - the lightweight capture/review panel, summoned by the right-Shift gesture
///   (or ⌘J), which stays focused on drafting and reviewing.
/// - a single on-demand management window (account, settings, history, pricing),
///   opened from this menu bar. It is never always-on and never steals focus
///   during ordinary input-support usage.
@main
struct BombSquadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var auth = AuthViewModel.shared

    var body: some Scene {
        MenuBarExtra {
            // At-a-glance running/account state.
            if auth.hasSession {
                Text(auth.signedInEmail ?? "ログイン済み")
                if let tier = auth.accountSummary?.tier.label {
                    Text("プラン: \(tier)")
                }
            } else {
                Text("未ログイン")
            }
            Divider()

            Button("入力パネルを開く（⌘J）") {
                appDelegate.togglePanelFromMenu()
            }
            Divider()

            Button(auth.hasSession ? "アカウント / マイページ…" : "ログイン / 新規登録…") {
                openManagement(.account)
            }
            Button("設定…") { openManagement(.settings) }
                .keyboardShortcut(",", modifiers: .command)
            Button("履歴…") { openManagement(.history) }
            Button("料金プラン…") { openManagement(.pricing) }
            Divider()

            Button("終了") { NSApplication.shared.terminate(nil) }
        } label: {
            // Monochrome I//O glyph (template image; design principle 3.5).
            Image(nsImage: MenuBarGlyph.image)
                .accessibilityLabel("Universal I/O")
        }
    }

    /// Point the (single) management window at a section and bring it front.
    private func openManagement(_ section: ManagementSection) {
        appDelegate.openManagementWindow(section: section)
    }
}
