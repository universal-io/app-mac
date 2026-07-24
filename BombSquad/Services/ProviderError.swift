import Foundation

/// Provider-neutral errors surfaced to the UI. Shared by all `ReviewProvider`
/// implementations so the view layer handles one error type.
enum ProviderError: UserPresentableError {
    case missingAPIKey
    case http(status: Int, body: String)
    case noStructuredOutput
    case decoding(String)
    case emptyDraft
    /// Gateway errors arrive with a user-facing message already resolved from
    /// the API error contract; show it as-is.
    case gateway(message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API キーが設定されていません。設定（Cmd+,）から登録してください。"
        case let .gateway(message):
            return message
        case let .http(status, body):
            if status == 401 { return "API キーが無効です（401）。設定を確認してください。" }
            if status == 429 { return "レート制限に達しました（429）。少し待って再試行してください。" }
            return "API エラー（\(status)）: \(body)"
        case .noStructuredOutput:
            return "モデルが構造化レビューを返しませんでした。再試行してください。"
        case let .decoding(detail):
            return "レビュー結果の解析に失敗しました: \(detail)"
        case .emptyDraft:
            return "レビューする下書きが空です。"
        }
    }
}
