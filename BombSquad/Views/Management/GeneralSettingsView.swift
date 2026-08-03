import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    @State private var recentEntries: [DiagnosticEntry] = []
    @State private var didCopyDiagnostics = false
    @AppStorage(AppSettings.isHistoryEnabledKey) private var isHistoryEnabled = true
    @AppStorage(AppSettings.isContextCaptureEnabledKey) private var isContextCaptureEnabled = true
    @AppStorage(AppSettings.isProactiveSuggestEnabledKey) private var isProactiveSuggestEnabled = true
    // Same fallback as AppSettings.outputLanguage(), so the picker never shows
    // a language the app is not actually using.
    @AppStorage(AppSettings.outputLanguageKey)
    private var outputLanguageID = OutputLanguage.systemDefault.rawValue

    let config: BombSquadConfig.Snapshot

    var body: some View {
        Form {
            Section("言語") {
                Picker("AIが返す言語", selection: $outputLanguageID) {
                    ForEach(OutputLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                Text("文案、レビュー、受信内容の要約、画面への回答をこの言語で返します。読み書きしている相手の言語とは無関係に選べます（日本語で書いて英語で送る、英語の画面を日本語で読む）。初期値はこのMacの言語設定です。アプリの表示自体は現在日本語のみです。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("接続") {
                configRow("Product API", entry: config.apiBaseURL)
                configRow("Supabase URL", entry: config.supabaseURL)
                configRow("Supabase anon key", entry: config.supabaseAnonKey)
                Text("AI機能はすべて本番のI//O Cloudを使用します。ローカルGatewayや端末APIキーへの切り替えはありません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("周辺コンテクスト") {
                Toggle("呼び出し時に画面の文脈を読み取る", isOn: $isContextCaptureEnabled)
            }

            Section("先回り文案") {
                Toggle("入力パネルを開いたら画面から文案を自動生成する", isOn: $isProactiveSuggestEnabled)
                Text("フォーカス中のフォームに入れる文案を、レビュー欄と同じ位置に自動表示します。毎回AIを使うため、オフにできます。オフでも画面の先読みは続くのでビジョンは速いままです。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("履歴") {
                Toggle("Composeの送信履歴をこのMacに保存", isOn: $isHistoryEnabled)
                Text("実際に送信したComposeの内容だけを最新 \(AppSettings.localHistoryLimit) 件保存します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            diagnosticsSection
        }
        .formStyle(.grouped)
        .navigationTitle("設定")
    }

    /// The動作記録 the user can hand over when something stalls.
    ///
    /// A device log the user cannot reach is a log only we can read, and asking
    /// a customer for a sysdiagnose is not a support flow. The same entries are
    /// therefore shown here and copied with one button. They are displayed, not
    /// just copied, because sending something you cannot read is not consent.
    private var diagnosticsSection: some View {
        Section("動作記録") {
            Text("操作の開始・送信・完了・失敗を、経過時間と結果コードだけで記録します。入力内容、AIの回答、画面画像、ウインドウのタイトル、開いているサイト名は含みません。うまく動かない時にこの記録を送っていただけると原因が特定できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if recentEntries.isEmpty {
                Text("まだ記録がありません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(recentEntries.map(\.line).joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }

            HStack {
                Button("動作記録をコピー") { copyDiagnostics() }
                if didCopyDiagnostics {
                    Text("コピーしました")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                Spacer()
                Button("更新") { refreshDiagnostics() }
                    .buttonStyle(.borderless)
            }
        }
        .onAppear(perform: refreshDiagnostics)
    }

    private func refreshDiagnostics() {
        recentEntries = Diagnostics.recent(40)
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.exportText(), forType: .string)
        refreshDiagnostics()
        withAnimation { didCopyDiagnostics = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { didCopyDiagnostics = false }
        }
    }

    @ViewBuilder
    private func configRow(_ title: String, entry: BombSquadConfig.Entry) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(entry.redactedValue)
                .font(.caption)
                .foregroundStyle(entry.isConfigured ? Color.secondary : .red)
                .textSelection(.enabled)
        }
        .help(entry.key)
    }
}
