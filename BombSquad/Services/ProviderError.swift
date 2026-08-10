import Foundation

/// Provider-neutral errors surfaced to the UI. Shared by all `ReviewProvider`
/// implementations so the view layer handles one error type.
enum ProviderError: UserPresentableError {
    case missingAPIKey
    case http(status: Int, body: String)
    /// The request never reached the Gateway: no network, DNS failure, dropped
    /// connection, TLS failure, timeout. Kept apart from `.http` because the
    /// two have opposite causes and opposite remedies — one is the user's
    /// connection, the other is our server — and collapsing them told the user
    /// "API エラー（-1）" while their Wi-Fi was off.
    case transport(code: Int, description: String)
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
        case let .transport(code, description):
            switch URLError.Code(rawValue: code) {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "インターネットに接続できませんでした。接続を確認して、もう一度お試しください。"
            case .timedOut:
                return "応答がありませんでした（タイムアウト）。もう一度お試しください。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "サーバーに接続できませんでした。接続を確認して、もう一度お試しください。"
            case .secureConnectionFailed, .serverCertificateUntrusted:
                return "安全な接続を確立できませんでした。ネットワークの設定を確認してください。"
            default:
                return "接続に失敗しました: \(description)"
            }
        case .noStructuredOutput:
            return "モデルが構造化レビューを返しませんでした。再試行してください。"
        case let .decoding(detail):
            return "レビュー結果の解析に失敗しました: \(detail)"
        case .emptyDraft:
            return "レビューする下書きが空です。"
        }
    }
}
