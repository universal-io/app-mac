import Foundation

/// Maps internal and system errors to messages a person can actually act on.
///
/// `message` is the main, human-readable line; `technicalDetail` is the raw
/// underlying string, meant to be shown small (or omitted when it would just
/// repeat the message). Centralized so every surface phrases failures the same
/// way and no cryptic system string — e.g. "The operation couldn't be
/// completed. (com.apple.AuthenticationServices.WebAuthenticationSession error
/// 1.)" — ever reaches a user as the primary message.
enum UserFacingError {
    /// ASWebAuthenticationSession's error domain. Its `localizedDescription` is
    /// the opaque "operation couldn't be completed" string, so we translate by
    /// domain/code instead. (code 1 = canceledLogin, 2/3 = presentation issues.)
    private static let webAuthDomain =
        "com.apple.AuthenticationServices.WebAuthenticationSession"

    static func message(for error: Error) -> String {
        let nsError = error as NSError

        switch nsError.domain {
        case webAuthDomain:
            return nsError.code == 1
                ? "ログインが完了しませんでした。もう一度お試しください。"
                : "ログイン画面を開けませんでした。アプリを再起動して、もう一度お試しください。"
        case NSURLErrorDomain:
            if nsError.code == NSURLErrorCancelled {
                return "通信を中止しました。もう一度お試しください。"
            }
            return "ネットワークに接続できませんでした。接続を確認して、もう一度お試しください。"
        default:
            break
        }

        // Our own error types (ProviderError, BombSquadAuthError,
        // ScreenshotCaptureError, …) already carry ready-to-show Japanese copy.
        // Bridged system errors are not LocalizedError, so this does not leak
        // their opaque strings.
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }

        return "問題が発生しました。もう一度お試しください。"
    }

    /// The raw underlying string, for a small secondary line beneath `message`.
    /// Nil when it is empty or would only repeat the primary message.
    static func technicalDetail(for error: Error) -> String? {
        let raw = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != message(for: error) else { return nil }
        return raw
    }
}
