import AppKit
import Foundation

enum InferredAppMode: Equatable, CustomStringConvertible {
    case idle
    case compose
    case transform
    case vision
    case navigator
    case copilot
    case capturing(previous: String)

    var description: String {
        switch self {
        case .idle: return "idle"
        case .compose: return "compose"
        case .transform: return "transform"
        case .vision: return "vision"
        case .navigator: return "navigator"
        case .copilot: return "copilot"
        case .capturing(let previous): return "capturing(previous=\(previous))"
        }
    }

    @MainActor
    static func infer(
        hasPanel: Bool,
        session: PanelSession?,
        isCapturingScreenshot: Bool,
        isSelectionOverlayPresenting: Bool,
    ) -> InferredAppMode {
        let base = inferBase(hasPanel: hasPanel, session: session)
        if isCapturingScreenshot || isSelectionOverlayPresenting || session?.viewModel.isCapturingScreenshot == true {
            return .capturing(previous: base.description)
        }
        return base
    }

    @MainActor
    private static func inferBase(
        hasPanel: Bool,
        session: PanelSession?
    ) -> InferredAppMode {
        guard hasPanel, let session else { return .idle }
        switch session.flowState {
        case .copilot:
            return .copilot
        case .navigator:
            return .navigator
        case .vision:
            return .vision
        case .text:
            return session.mode == .transform ? .transform : .compose
        }
    }
}

enum SessionTrace {
    static func event(
        _ name: String,
        mode: InferredAppMode,
        details: [String: CustomStringConvertible?] = [:]
    ) {
        #if DEBUG
        let detailText = details
            .compactMap { key, value -> String? in
                guard let value else { return nil }
                return "\(key)=\(value)"
            }
            .sorted()
            .joined(separator: " ")
        if detailText.isEmpty {
            NSLog("[SessionTrace] %@ mode=%@", name, mode.description)
        } else {
            NSLog("[SessionTrace] %@ mode=%@ %@", name, mode.description, detailText)
        }
        #endif
    }
}
