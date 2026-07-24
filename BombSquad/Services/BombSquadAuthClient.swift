import Foundation
import Supabase

/// Keeps the Supabase session in a Universal I/O-specific Keychain service.
/// Older builds used the SDK-wide default item; import it at most once, then
/// never consult it again so signing in/out cannot resurrect a stale session.
private struct UniversalIOAuthLocalStorage: AuthLocalStorage {
    static let storageKey = "com.universal-io.mac.auth.skcsbcyivjcvevxntvqa"

    private static let migrationFlag = "auth.keychainScopedMigration.v1"
    private let scoped = KeychainLocalStorage(service: "com.universal-io.mac.supabase")
    private let legacy = KeychainLocalStorage()

    func store(key: String, value: Data) throws {
        try scoped.store(key: key, value: value)
        if key == Self.storageKey {
            UserDefaults.standard.set(true, forKey: Self.migrationFlag)
        }
    }

    func retrieve(key: String) throws -> Data? {
        if let data = try? scoped.retrieve(key: key) {
            return data
        }
        guard key == Self.storageKey,
              !UserDefaults.standard.bool(forKey: Self.migrationFlag)
        else { return nil }

        // Current SDK default first, then the oldest pre-migration key.
        for legacyKey in ["supabase.auth.token", "supabase.session"] {
            if let data = try? legacy.retrieve(key: legacyKey) {
                try scoped.store(key: key, value: data)
                UserDefaults.standard.set(true, forKey: Self.migrationFlag)
                return data
            }
        }
        UserDefaults.standard.set(true, forKey: Self.migrationFlag)
        return nil
    }

    func remove(key: String) throws {
        // Mark first: even if the scoped item is already absent, sign-out must
        // never fall back to the old shared SDK item on the next launch.
        if key == Self.storageKey {
            UserDefaults.standard.set(true, forKey: Self.migrationFlag)
        }
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
