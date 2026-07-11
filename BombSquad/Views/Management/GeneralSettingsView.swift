import SwiftUI

/// App configuration: review model selection, per-vendor API keys, and the
/// read-only backend/auth config snapshot. Account sign-in lives in `AccountView`;
/// this section is purely technical settings.
struct GeneralSettingsView: View {
    @AppStorage(AppSettings.selectedModelKey) private var selectedModelID = ReviewModel.defaultModel.id
    @AppStorage(AppSettings.selectedVisionModelKey) private var selectedVisionModelID = AppSettings.defaultVisionModelID
    @AppStorage(AppSettings.isHistoryEnabledKey) private var isHistoryEnabled = true
    @AppStorage(AppSettings.isContextCaptureEnabledKey) private var isContextCaptureEnabled = true
    @AppStorage(AppSettings.isMemoryEnabledKey) private var isMemoryEnabled = true
    @AppStorage(AppSettings.isNavigatorEnabledKey) private var isNavigatorEnabled = true
    @AppStorage(AppSettings.isNavigatorAutoFirstTurnEnabledKey) private var isNavigatorAutoFirstTurnEnabled = true
    @AppStorage(AppSettings.outputLanguageKey) private var outputLanguageID = OutputLanguage.japanese.rawValue

    let config: BombSquadConfig.Snapshot
    @State private var openAIKey: String = ""
    @State private var anthropicKey: String = ""
    @State private var groqKey: String = ""
    @State private var saved = false

    private var selectedModel: ReviewModel {
        ReviewModel.find(id: selectedModelID)
    }

    private var isCloudRoutingEnabled: Bool {
        config.hasBackendConfig
    }

    var body: some View {
        Form {
            Section("出力言語") {
                Picker("結果の言語", selection: $outputLanguageID) {
                    ForEach(OutputLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                Text("レビュー結果（送る文／読みやすくした文）の言語です。入力が何語でも結果はこの言語になります。次にパネルを開いた時から反映されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("AI ルーティング") {
                aiRouteRow(
                    title: "入力レビュー",
                    summary: isCloudRoutingEnabled
                        ? "I//O Cloud (`/ai/review`) が担当"
                        : selectedModel.displayName,
                    note: isCloudRoutingEnabled
                        ? "普段の文章レビューはサーバー側でモデル選択されます。下の「レビューモデル」は Cloud 未接続時のフォールバックです。"
                        : "この Mac に保存した API キーで直接レビューします。"
                )
                aiRouteRow(
                    title: "受信メッセージの整理",
                    summary: isCloudRoutingEnabled
                        ? "I//O Cloud (`/ai/vision`) が担当"
                        : "OpenAI · \(effectiveVisionModelID)",
                    note: isCloudRoutingEnabled
                        ? "メッセージの解釈と返信案は Vision 系のクラウド経路です。実際の `model_id` は応答ごとに返り、パネル右上には最後に完了した応答のモデル名が出ます。"
                        : "OpenAI Responses API を直接使用します。"
                )
                aiRouteRow(
                    title: "スクショ直後のざっくり解釈",
                    summary: navigatorCaptureSummary,
                    note: navigatorCaptureNote
                )
                aiRouteRow(
                    title: "コパイロット継続中の推論",
                    summary: navigatorFollowupSummary,
                    note: navigatorFollowupNote
                )
                Text("Cloud 経由のモデル切り替えは現在サーバー側の責務です。この画面では、どの操作がどの経路へ行くかを開発用に可視化しています。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("レビューモデル（ローカル/BYOK フォールバック）") {
                Picker("使用するモデル", selection: $selectedModelID) {
                    ForEach(ReviewModel.catalog) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
                Text(selectedModel.hint)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isCloudRoutingEnabled {
                    Text("クラウド接続（I//O Cloud）が有効なため、通常のレビューはサーバー側でモデルが選択されます。このモデル選択と API キーは、クラウド未接続時の開発者向けフォールバックにのみ使われます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Vision / Copilot") {
                Toggle("スクリーンショットを Navigator / Copilot 経路で扱う", isOn: $isNavigatorEnabled)
                Toggle("スクショ取得直後に自動で初手を走らせる", isOn: $isNavigatorAutoFirstTurnEnabled)
                    .disabled(!isNavigatorEnabled)
                TextField("OpenAI Responses model ID（例: gpt-5.4-mini）", text: $selectedVisionModelID)
                    .textFieldStyle(.roundedBorder)
                Text("このモデル ID は Cloud 未接続時、または Navigator を使わず legacy Vision を使う時の OpenAI フォールバックです。既定は `\(AppSettings.defaultVisionModelID)`、失敗時は `gpt-4.1-mini` に一段フォールバックします。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isCloudRoutingEnabled {
                    Text("Cloud 接続中の Navigator はサーバー側で高速 stage と後続 stage を切り替えます。精度重視で実際のクラウドモデルを変える場合は Gateway 側のルーティング変更が必要です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Groq API") {
                SecureField(APIVendor.groq.keyPlaceholder, text: $groqKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("OpenAI API") {
                SecureField(APIVendor.openAI.keyPlaceholder, text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Claude API") {
                SecureField(APIVendor.anthropic.keyPlaceholder, text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Backend / Auth") {
                configRow("Product API", entry: config.apiBaseURL)
                configRow("Supabase URL", entry: config.supabaseURL)
                configRow("Supabase anon key", entry: config.supabaseAnonKey)

                Text("値の読み取り順は `BombSquad.local.plist` → `ProcessInfo.environment` → `Info.plist` です。通常はリポジトリ直下の `BombSquad.local.plist` を使います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("周辺コンテクスト") {
                Toggle("呼び出し時に画面の文脈を読み取る", isOn: $isContextCaptureEnabled)
                Text("パネルを呼び出した瞬間に、前面アプリと周辺の会話テキストを読み取ってレビューの参考にします。読み取った内容はパネル上のチップから確認・除外でき、保存はされません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("メモリ") {
                Toggle("スタイルプロファイルを反映・学習する", isOn: $isMemoryEnabled)
                Text("レビュー時にあなたの文体プロファイルと相手ごとのメモを参照し、送信のたびに少しずつ学習します。内容は「メモリ」タブでいつでも確認・編集・削除できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("履歴") {
                Toggle("ローカル履歴を保存", isOn: $isHistoryEnabled)
                Text("現在の履歴はこの Mac の SQLite にだけ保存します。クラウド同期はまだ行いません。保存上限は最新 \(AppSettings.localHistoryLimit) 件です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Text("キーは Keychain に保存され、リポジトリやファイルには書き込まれません。設定したベンダーのモデルだけ利用できます。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("保存") { save() }
                        .buttonStyle(.borderedProminent)
                    if saved {
                        Label("保存しました", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("設定")
        .onAppear(perform: load)
        .onChange(of: openAIKey) { _, _ in saved = false }
        .onChange(of: anthropicKey) { _, _ in saved = false }
        .onChange(of: groqKey) { _, _ in saved = false }
    }

    private func load() {
        groqKey = KeychainStore.apiKey(account: APIVendor.groq.keychainAccount) ?? ""
        openAIKey = KeychainStore.apiKey(account: APIVendor.openAI.keychainAccount) ?? ""
        anthropicKey = KeychainStore.apiKey(account: APIVendor.anthropic.keychainAccount) ?? ""
    }

    private func save() {
        KeychainStore.saveAPIKey(groqKey, account: APIVendor.groq.keychainAccount)
        KeychainStore.saveAPIKey(openAIKey, account: APIVendor.openAI.keychainAccount)
        KeychainStore.saveAPIKey(anthropicKey, account: APIVendor.anthropic.keychainAccount)
        saved = true
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

    private var effectiveVisionModelID: String {
        let trimmed = selectedVisionModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppSettings.defaultVisionModelID : trimmed
    }

    private var navigatorCaptureSummary: String {
        if isCloudRoutingEnabled && isNavigatorEnabled {
            return isNavigatorAutoFirstTurnEnabled
                ? "I//O Cloud (`/ai/navigate`) 自動初手"
                : "Navigator 待機（最初の質問で `/ai/navigate`）"
        }
        if isCloudRoutingEnabled {
            return "I//O Cloud (`/ai/vision`) 単発解釈"
        }
        return "OpenAI · \(effectiveVisionModelID)"
    }

    private var navigatorCaptureNote: String {
        if isCloudRoutingEnabled && isNavigatorEnabled {
            return isNavigatorAutoFirstTurnEnabled
                ? "取得した画面をそのまま読ませる最初の一手です。現在のクラウド実装ではこの段階と後続ターンで別モデルを使い分けられます。"
                : "スクショだけ撮って待機し、ユーザーが最初の質問を送った時点で Navigator が走ります。"
        }
        if isCloudRoutingEnabled {
            return "Navigator を使わない設定では、従来の `/ai/vision` 単発解釈に戻ります。"
        }
        return "Cloud 未接続時は OpenAI Responses API をこの Mac から直接呼びます。"
    }

    private var navigatorFollowupSummary: String {
        if isCloudRoutingEnabled && isNavigatorEnabled {
            return "I//O Cloud (`/ai/navigate`) 後続ターン / Copilot"
        }
        return "未使用"
    }

    private var navigatorFollowupNote: String {
        if isCloudRoutingEnabled && isNavigatorEnabled {
            return "進行チェックや追質問のたびに最新キャプチャを送り直す経路です。パネル右上のモデル名は、最後に完了した応答が返した `model_id` を表示します。"
        }
        return "Navigator / Copilot を有効にした時だけ使います。"
    }

    @ViewBuilder
    private func aiRouteRow(title: String, summary: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                Spacer()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
