import Foundation
import Supabase

/// Keeps the Supabase session in a Keychain item belonging to *this build*.
///
/// **Why the bundle identifier is in the service name.** macOS protects a
/// legacy Keychain item with an ACL that names the application allowed to touch
/// it, and that name is the app's code signature. The Supabase SDK does not opt
/// into the data-protection keychain, so its items land in the legacy one and
/// inherit that behaviour.
///
/// This service string used to be the literal `com.universal-io.mac.supabase`
/// for every configuration, which meant the installed production app (signed
/// Developer ID) and a development build (signed Apple Development) shared one
/// item and took turns owning its ACL. The visible symptom was the one that
/// kept coming back: run the dev build after the production app and macOS asks
/// for the login password, once for reading and again when a token refresh
/// writes — every rebuild, forever, because whichever app wrote last is the one
/// the ACL trusts.
///
/// Deriving the service from the bundle identifier ends that: production keeps
/// the exact string it has always used (`com.universal-io.mac` + `.supabase`),
/// so no shipped session is lost, and the dev build gets an item of its own to
/// own outright.
///
/// This does not make the prompt impossible — a change of signing identity
/// still invalidates an ACL — but it removes the one cause that fired on every
/// build. If it is ever seen again on a build signed the same way as the last
/// one, the remaining fix is to leave the legacy keychain entirely
/// (`kSecUseDataProtectionKeychain`), which needs a provisioning profile and is
/// therefore a separate decision.
private struct UniversalIOAuthLocalStorage: AuthLocalStorage {
    static let storageKey = "com.universal-io.mac.auth.skcsbcyivjcvevxntvqa"

    private static var service: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.universal-io.mac"
        return "\(bundleID).supabase"
    }

    private let scoped = KeychainLocalStorage(service: UniversalIOAuthLocalStorage.service)

    func store(key: String, value: Data) throws {
        try scoped.store(key: key, value: value)
    }

    func retrieve(key: String) throws -> Data? {
        try? scoped.retrieve(key: key)
    }

    func remove(key: String) throws {
        try? scoped.remove(key: key)
    }
}

enum BombSquadAuthError: UserPresentableError {
    case missingConfiguration
    case invalidSupabaseURL(String)
    case invalidEmail

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Supabase の設定が不足しています。設定値を確認してください。"
        case .invalidSupabaseURL(let value):
            return "Supabase URL が不正です: \(value)"
        case .invalidEmail:
            return "メールアドレスを入力してください。"
        }
    }
}

final class BombSquadAuthClient {
    static let shared = BombSquadAuthClient()
    // C4 rebrand: must be listed in Supabase Auth > URL Configuration >
    // Redirect URLs (the legacy bombsquad:// entry can be removed once all
    // installs have migrated).
    static let redirectURL = URL(string: "universal-io://auth/callback")!

    typealias AuthStateChange = (event: AuthChangeEvent, session: Session?)

    private let config: BombSquadConfig.Snapshot
    private let client: SupabaseClient?

    init(config: BombSquadConfig.Snapshot = BombSquadConfig.snapshot()) {
        self.config = config

        guard config.hasSupabaseConfig else {
            self.client = nil
            return
        }

        guard let urlString = config.supabaseURL.value else {
            self.client = nil
            return
        }

        guard let url = URL(string: urlString) else {
            self.client = nil
            return
        }

        self.client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: config.supabaseAnonKey.value ?? "",
            options: SupabaseClientOptions(
                auth: .init(
                    storage: UniversalIOAuthLocalStorage(),
                    storageKey: UniversalIOAuthLocalStorage.storageKey,
                    autoRefreshToken: true,
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }

    var isConfigured: Bool {
        client != nil
    }

    func authStateChanges() -> AsyncStream<AuthStateChange> {
        guard let client else {
            return AsyncStream { continuation in
                continuation.yield((.initialSession, nil))
                continuation.finish()
            }
        }
        return client.auth.authStateChanges
    }

    func currentSession() -> Session? {
        client?.auth.currentSession
    }

    func currentUserEmail() -> String? {
        client?.auth.currentUser?.email
    }

    func currentUserID() -> UUID? {
        client?.auth.currentUser?.id
    }

    func sendMagicLink(email: String) async throws {
        guard let client else {
            throw missingConfigurationError()
        }

        let normalizedEmail = normalize(email)
        guard isValidEmail(normalizedEmail) else {
            throw BombSquadAuthError.invalidEmail
        }

        // Supabase の API 名は signInWithOTP だが、現在の Bomb Squad では
        // メールテンプレートを ConfirmationURL ベースにしているため、
        // 実際のユーザー体験は「コード入力」ではなく「メールリンクを開く」方式。
        try await client.auth.signInWithOTP(
            email: normalizedEmail,
            redirectTo: Self.redirectURL
        )
    }

    @discardableResult
    func signInWithGoogle() async throws -> Session {
        guard let client else {
            throw missingConfigurationError()
        }

        return try await client.auth.signInWithOAuth(
            provider: .google,
            redirectTo: Self.redirectURL,
            // Always show Google's account chooser. Without this the web session
            // silently reuses whichever Google account it already holds, forcing
            // a user with several accounts to cancel and retry to switch; the
            // chooser (with "Use another account") lets them pick every time.
            queryParams: [(name: "prompt", value: "select_account")]
        )
    }

    @discardableResult
    func handleIncomingURL(_ url: URL) async throws -> Session {
        guard let client else {
            throw missingConfigurationError()
        }

        return try await client.auth.session(from: url)
    }

    @discardableResult
    func bootstrapCurrentUser() async throws -> UUID {
        guard let client else {
            throw missingConfigurationError()
        }

        let tenantID: UUID = try await client.rpc("bs_initialize_current_user").execute().value
        return tenantID
    }

    func accessToken() async throws -> String {
        guard let client else {
            throw missingConfigurationError()
        }
        return try await client.auth.session.accessToken
    }

    func signOut() async throws {
        guard let client else {
            throw missingConfigurationError()
        }
        try await client.auth.signOut()
    }

    private func missingConfigurationError() -> Error {
        if let value = config.supabaseURL.value,
           URL(string: value) == nil {
            return BombSquadAuthError.invalidSupabaseURL(value)
        }
        return BombSquadAuthError.missingConfiguration
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isValidEmail(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.contains("@") && value.contains(".")
    }
}
