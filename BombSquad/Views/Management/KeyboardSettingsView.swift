import SwiftUI

/// Keyboard settings tab: every key the app listens to, in one place.
/// - The gesture key (default Right Shift) drives tap / double-tap /
///   long-press; changing it takes effect immediately (the monitor reads the
///   setting per event).
/// - Tap timing thresholds are tunable for motor-accessibility reasons.
/// Values are stored locally (UserDefaults); account sync is a later phase.
struct KeyboardSettingsView: View {
    @AppStorage(KeybindingSettings.gestureKeyKey)
    private var gestureKeyID = KeybindingSettings.defaultGestureKey.rawValue
    @AppStorage(KeybindingSettings.doubleTapThresholdMsKey)
    private var doubleTapThresholdMs = KeybindingSettings.defaultDoubleTapThresholdMs
    @AppStorage(KeybindingSettings.longPressThresholdMsKey)
    private var longPressThresholdMs = KeybindingSettings.defaultLongPressThresholdMs

    private var gestureKey: GestureKey {
        GestureKey(rawValue: gestureKeyID) ?? KeybindingSettings.defaultGestureKey
    }

    var body: some View {
        Form {
            Section("呼び出しキー（ジェスチャ）") {
                Picker("使用するキー", selection: $gestureKeyID) {
                    ForEach(GestureKey.allCases) { key in
                        Text(key.displayName).tag(key.rawValue)
                    }
                }
                if let caution = gestureKey.caution {
                    Label(caution, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("タップや長押しに使えるのは修飾キーのみです（通常のキーは文字が入力されてしまうため）。変更は即座に反映されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("ジェスチャの割り当て") {
                bindingRow("\(gestureKey.hintLabel) 1回タップ", "原文欄 ⇄ レビュー結果欄のフォーカス切替")
                bindingRow("\(gestureKey.hintLabel) 2回タップ", "起動 / レビュー / ビジョン / 閉じる")
                bindingRow("\(gestureKey.hintLabel) 長押し", "音声入力（押している間だけ録音）")
                Text("3つのジェスチャは同じキーに揃えています（覚えやすさのため）。個別の割り当ては現在サポートしていません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("タイミング調整") {
                thresholdRow(
                    title: "2回タップの間隔",
                    value: $doubleTapThresholdMs,
                    range: 200...600,
                    note: "この時間内に2回押すとダブルタップと判定します。長くするとゆっくり押しても反応し、短くすると誤動作が減ります。"
                )
                thresholdRow(
                    title: "長押しの判定時間",
                    value: $longPressThresholdMs,
                    range: 150...600,
                    note: "この時間以上押し続けると音声入力が始まります。"
                )
            }

            Section("固定キー（変更不可）") {
                bindingRow("Enter", "カーソルがある側を送信")
                bindingRow("Shift + Enter", "改行")
                bindingRow("esc", "パネルを閉じる / 1つ戻る")
            }

            Section {
                Button("すべて既定に戻す") {
                    KeybindingSettings.resetToDefaults()
                }
                Text("現在の設定はこの Mac にのみ保存されます。アカウントへの同期（複数の Mac で共有）は今後対応予定です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("キーボード")
    }

    @ViewBuilder
    private func bindingRow(_ key: String, _ action: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key)
                .font(.system(.body, design: .monospaced))
            Spacer()
            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func thresholdRow(
        title: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        note: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value.wrappedValue) ms")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int(($0 / 10).rounded() * 10) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}
