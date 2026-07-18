import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.isHistoryEnabledKey) private var isHistoryEnabled = true
    @AppStorage(AppSettings.isContextCaptureEnabledKey) private var isContextCaptureEnabled = true
    @AppStorage(AppSettings.isMemoryEnabledKey) private var isMemoryEnabled = true
    @AppStorage(AppSettings.outputLanguageKey) private var outputLanguageID = OutputLanguage.japanese.rawValue

    let config: BombSquadConfig.Snapshot

    var body: some View {
        Form {
            Section("出力言語") {
                Picker("結果の言語", selection: $outputLanguageID) {
                    ForEach(OutputLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
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

            Section("メモリ") {
                Toggle("スタイルプロファイルを反映・学習する", isOn: $isMemoryEnabled)
            }

            Section("履歴") {
                Toggle("ローカル履歴を保存", isOn: $isHistoryEnabled)
                Text("履歴はこのMacのみに最新 \(AppSettings.localHistoryLimit) 件保存します。")
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
