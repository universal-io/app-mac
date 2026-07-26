import SwiftUI

struct GeneralSettingsView: View {
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
                Text("実際に送信した内容だけを最新 \(AppSettings.localHistoryLimit) 件保存します。Transformは保存しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("設定")
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
