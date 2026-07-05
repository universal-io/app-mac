import SwiftUI

/// First-run setup: a single focused window that requests the three system
/// permissions one row at a time. Shown at launch only when something is
/// missing (staying out of the way otherwise honors the lightness priority),
/// and being a real key window it keeps the system prompts on-screen instead
/// of scattering them across displays.
struct PermissionsSetupView: View {
    @ObservedObject var coordinator: PermissionsCoordinator
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Universal I/O のセットアップ")
                    .font(.title2).bold()
                Text("3つの許可で使えるようになります。初回はキーチェーンの確認が数回出ることがあります — 「常に許可」を選んでください。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                ForEach(PermissionsCoordinator.Kind.allCases) { kind in
                    PermissionRow(
                        kind: kind,
                        granted: coordinator.isGranted(kind),
                        action: { coordinator.request(kind) },
                        openSettings: { coordinator.openSettings(kind) }
                    )
                }
            }

            HStack {
                if coordinator.allGranted {
                    Label("すべて許可されました", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button(coordinator.allGranted ? "使い始める" : "あとで") {
                    onDone()
                }
                .keyboardShortcut(coordinator.allGranted ? .defaultAction : .cancelAction)
            }
        }
        .padding(24)
        .frame(width: 470)
        .onAppear { coordinator.startMonitoring() }
        .onDisappear { coordinator.stopMonitoring() }
    }
}

private struct PermissionRow: View {
    let kind: PermissionsCoordinator.Kind
    let granted: Bool
    let action: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : kind.systemImage)
                .font(.title2)
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title).font(.headline)
                Text(kind.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !granted {
                    // Denied case: the system prompt no longer appears, so
                    // offer a direct path to Settings without the primary
                    // button ever stealing focus to it.
                    Button("ダイアログが出ないときはシステム設定を開く", action: openSettings)
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            }

            Spacer(minLength: 12)

            if granted {
                Text("許可済み")
                    .font(.caption).bold()
                    .foregroundStyle(.green)
            } else {
                Button("許可", action: action)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}
