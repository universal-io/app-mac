import AppKit
import SwiftUI

/// What the app did to produce this answer, for the info button beside the
/// skill name.
///
/// Lifted out of the static Vision panel when that was removed (R14 F11). The
/// bubble is the only place the product speaks now, so this had to move with
/// it: an operator who cannot see the model, the route, the accessibility walk
/// and the capture cannot tell a wrong answer from a broken pipeline. Content
/// and wording are unchanged from the panel's version.
///
/// Reads the session and derives a string. No state of its own, so it cannot
/// disagree with what the session actually holds. On the main actor because the
/// session is — it is read from a view being drawn there.
@MainActor
enum VisionDiagnosticsReport {
    static func text(for session: VisionSession) -> String {
        var lines = [
            "Universal I/O Vision diagnostics",
            "",
            "[capture]",
            "id: \(session.attachment.id.uuidString.lowercased())",
            "created_at: \(Self.iso8601.string(from: session.attachment.createdAt))",
            "scope: \(session.attachment.captureScope.rawValue)",
            "pixel_size: \(optionalSize(session))",
            "screen_rect: \(Self.describe(session.attachment.captureRect))",
            "",
            "[skill]",
            "active: \(session.activeSkillName ?? "none")",
            "",
            "[gateway]",
        ]

        if let metadata = session.metadata {
            lines += [
                "model_vendor: \(metadata.modelVendor)",
                "model_id: \(metadata.modelID)",
                "route: \(metadata.route)",
                "api: \(metadata.api)",
                "image_detail: \(metadata.imageDetail)",
                "reasoning_effort: \(metadata.reasoningEffort)",
                "fallback_used: \(metadata.fallbackUsed)",
                "latency_ms: \(metadata.latencyMs)",
            ]
        } else {
            lines.append("status: waiting")
        }

        lines += ["", "[selection]"]
        if let selection = session.selection {
            let visibleFrameCount = selection.visibleNormalizedFrames(in: session.attachment).count
            let wireTruncated = selection.wirePayload(for: session.attachment)?["wire_truncated"]
                as? Bool ?? false
            lines += [
                "acquisition: \(selection.acquisition.rawValue)",
                "structure_count: \(selection.structures.count)",
                "frame_count: \(selection.frames.count)",
                "visible_frame_count: \(visibleFrameCount)",
                "acquisition_completeness: \(selection.acquisitionCompleteness.rawValue)",
                "capture_visibility: \(selection.captureVisibility.rawValue)",
                "wire_truncated: \(wireTruncated)",
            ]
        } else {
            lines.append("status: none")
        }

        lines += ["", "[accessibility]"]
        if let diagnostics = session.candidateDiagnostics {
            lines += [
                "status: \(diagnostics.truncatedReason ?? "complete")",
                "elapsed_ms: \(diagnostics.elapsedMs)",
                "visited_nodes: \(diagnostics.visitedNodes)",
                "candidate_count: \(diagnostics.candidateCount)",
                "collection_root: \(diagnostics.collectionRoot)",
                "capture_scope: \(diagnostics.captureScope)",
                "collection_passes: \(diagnostics.collectionPasses)",
                "web_area_present: \(diagnostics.webAreaPresent)",
                "target_app: \(diagnostics.targetAppName ?? "none")",
                "target_bundle_id: \(diagnostics.targetBundleID ?? "none")",
                "target_window: \(diagnostics.targetWindowTitle ?? "none")",
            ]
        } else {
            lines.append("status: collecting")
        }

        lines += ["", "[selected_candidate]"]
        if let candidate = session.selectedCandidate {
            lines += [
                "id: \(candidate.id)",
                "source: \(candidate.source)",
                "role: \(candidate.role ?? "none")",
                "label: \(candidate.label)",
                "parent_label: \(candidate.parentLabel ?? "none")",
                "states: \(candidate.states.isEmpty ? "none" : candidate.states.joined(separator: ", "))",
                "rect: \(Self.describe(candidate.rect))",
            ]
        } else {
            lines.append("status: none")
        }

        return lines.joined(separator: "\n")
    }

    private static func optionalSize(_ session: VisionSession) -> String {
        guard let width = session.attachment.pixelWidth,
              let height = session.attachment.pixelHeight else {
            return "unknown"
        }
        return "\(width)x\(height)"
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func describe(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return String(
            format: "x=%.4f y=%.4f width=%.4f height=%.4f",
            rect.minX, rect.minY, rect.width, rect.height
        )
    }

}

struct VisionDiagnosticsPopover: View {
    let report: String

    var body: some View {
        PanelInformationPopover(
            title: "Visionの処理情報",
            copyText: report,
            note:
                "開発とトラブルシューティング用です。画像・入力本文・回答本文は含みませんが、"
                    + "ウィンドウ名や選択候補ラベルを含む場合があります。"
        ) {
            ScrollView([.vertical, .horizontal]) {
                Text(report)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 480, height: 360)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
    }
}

