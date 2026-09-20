#if DEBUG
import SwiftUI

struct JevCandidateExperimentView: View {
    @ObservedObject var experiment: JevCandidateExperiment
    let goal: String
    let refreshAX: () -> Void
    let exportAX: () -> Void
    let copyAX: () -> Void
    let deleteAXExport: () -> Void
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Jev候補実験").font(.headline)
            Text(goal).font(.callout).textSelection(.enabled)
            Text("AX候補を確認し、必要なら一時JSONへ保存します。Gateway送信・画像送信・自動操作は行いません。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("AX候補だけ確認", action: refreshAX).disabled(experiment.isLoading)
                Button("AX結果を一時JSONへ", action: exportAX).disabled(experiment.axProbe == nil)
            }
            HStack {
                Button("AX結果をコピー", action: copyAX)
                    .disabled(experiment.axProbe == nil)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("通常の案内に戻る", action: stop)
            }
            .controlSize(.small)
            if experiment.isLoading {
                HStack { ProgressView().controlSize(.small); Text("候補を確認中…") }
            }
            if let message = experiment.message {
                Text(message).font(.callout).textSelection(.enabled)
            }
            if let sample = experiment.sample {
                Text(sample.choseNone ? "今回は判断保留が最上位です" : "次の操作対象の候補")
                    .font(.subheadline).bold()
                ForEach(sample.rows) { row in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label).textSelection(.enabled)
                            if let parent = row.parent, !parent.isEmpty {
                                Text(parent).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(row.probability, format: .percent.precision(.fractionLength(1)))
                            .monospacedDigit()
                    }
                }
                Text("判断保留 \(sample.noneProbability, format: .percent.precision(.fractionLength(1)))")
                Text("選択確率は目的の達成率ではありません。確信度 \(sample.confidence, format: .number.precision(.fractionLength(2)))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("AX \(sample.axMs) ms ・ 往復 \(sample.roundTripMs) ms ・ 合計 \(sample.totalMs) ms")
                    .font(.caption).monospacedDigit()
                Text("Jev \(sample.providerMs) ms ・ 入力 \(sample.inputTokens) tokens ・ 候補 \(sample.candidateCount)件")
                    .font(.caption).monospacedDigit()
                if let note = sample.collectionNote {
                    Text("AX取得は一部です（\(note)）。目的の対象が含まれない可能性があります。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("取得 \(sample.observedAt, style: .time)。操作時に破棄します。画面だけの自動更新は未監視のため、選ぶ前に再取得してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let probe = experiment.axProbe {
                Divider()
                Text("AX読み取り結果（Gateway送信なし）").font(.subheadline).bold()
                let appName = probe.diagnostics.targetAppName ?? "対象不明"
                let webArea = probe.diagnostics.webAreaPresent ? "あり" : "なし"
                Text("\(appName) ・ \(probe.candidates.count)件 ・ \(probe.diagnostics.elapsedMs) ms ・ 訪問 \(probe.diagnostics.visitedNodes) ・ pass \(probe.diagnostics.collectionPasses) ・ webArea \(webArea)")
                    .font(.caption).monospacedDigit().textSelection(.enabled)
                if let reason = probe.diagnostics.truncatedReason {
                    Text("取得理由: \(reason)").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(probe.candidates, id: \.id) { candidate in
                    let role = candidate.role ?? "—"
                    let rect = candidate.rect?.debugDescription ?? "—"
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(candidate.id)  [\(role)]  \(candidate.label)").textSelection(.enabled)
                        Text("parent: \(candidate.parentLabel ?? "—") ・ states: \(candidate.states.joined(separator: ", ")) ・ rect: \(rect)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Text("取得 \(probe.observedAt, style: .time)。この表示は一時的なメモリ上の診断です。")
                    .font(.caption).foregroundStyle(.secondary)
                if let url = experiment.axExportURL {
                    HStack {
                        Text(url.path).font(.caption2).textSelection(.enabled)
                        Button("一時JSONを削除", action: deleteAXExport)
                            .controlSize(.small)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
