import Foundation

/// Marks an error type whose `errorDescription` is already written for end
/// users (Japanese, actionable). `UserFacingError` trusts these as the primary
/// message; every other `LocalizedError` (e.g. an SDK error carrying an English
/// string) is treated as opaque and shown a friendly line instead.
protocol UserPresentableError: LocalizedError {}

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

        // Only our own error types carry ready-to-show Japanese copy. SDK
        // errors (Supabase AuthError/Postgrest, …) are LocalizedError too but
        // hold English strings, so trusting bare LocalizedError would leak
        // them; require the explicit marker instead.
        if let presentable = error as? UserPresentableError,
           let description = presentable.errorDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }

        return "問題が発生しました。もう一度お試しください。"
    }

    /// The reason, when the failure already explains itself in terms the user
    /// can act on; nil when it does not.
    ///
    /// A surface that fails has two things it can say: its own sentence about
    /// what did not happen ("文字起こしに失敗しました"), or the reason it did
    /// not happen ("今月の利用枠を使い切りました"). The first is the only one
    /// the caller can write in advance, so that is what every catch block held
    /// — and a user out of quota was told to try again, which is advice that
    /// cannot work. The gateway's own refusals and the transport's own failures
    /// arrive already phrased for a person and already actionable; those
    /// replace the surface's sentence. Everything else (a decode failure, an
    /// HTTP body) is an internal fact, not an instruction, and is left to the
    /// caller's wording.
    static func serverExplanation(for error: Error) -> String? {
        if let provider = error as? ProviderError {
            switch provider {
            case let .gateway(message, _):
                return message
            case .transport:
                return provider.errorDescription
            default:
                return nil
            }
        }
        if (error as NSError).domain == NSURLErrorDomain,
           !isUserCancellation(error) {
            return message(for: error)
        }
        return nil
    }

    /// Whether the error is the user intentionally backing out (closing the
    /// web sign-in sheet, cancelling a request) — a normal action, not a
    /// failure, so callers can avoid an alarming red banner.
    static func isUserCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == webAuthDomain, nsError.code == 1 { return true }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return true }
        return false
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
