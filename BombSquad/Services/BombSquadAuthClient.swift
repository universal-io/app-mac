import Foundation
import Security
import Supabase

/// Minimal wrapper over the macOS *data-protection* keychain
/// (`kSecUseDataProtectionKeychain`). Unlike the legacy file (login) keychain
/// the Supabase SDK's `KeychainLocalStorage` uses, data-protection items are
/// authorized by the app's `keychain-access-groups` entitlement — not by an
/// ACL bound to a specific code signature. As a result macOS never shows the
/// "wants to use the login keychain" save prompt, and a rebuild (new CDHash)
/// or a stray ad-hoc build can never invalidate access. Device-only and not
/// synced to iCloud.
private enum DataProtectionKeychain {
    struct Error: Swift.Error { let status: OSStatus }

    private static func baseQuery(
        service: String,
        account: String,
        accessGroup: String?
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // A non-sandboxed macOS app can use the data-protection keychain
        // without an explicit access group (the item then belongs to the app's
        // own default group). An explicit team group would need the
        // keychain-access-groups entitlement, which requires a provisioning
        // profile under this project's manual signing — deliberately avoided.
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    static func set(
        _ data: Data,
        service: String,
        account: String,
        accessGroup: String?
    ) throws {
        let base = baseQuery(service: service, account: account, accessGroup: accessGroup)
        var addQuery = base
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(
                base as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else { throw Error(status: updateStatus) }
        default:
            throw Error(status: addStatus)
        }
    }

    static func get(
        service: String,
        account: String,
        accessGroup: String?
    ) throws -> Data? {
        var query = baseQuery(service: service, account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw Error(status: status)
        }
    }

    static func delete(
        service: String,
        account: String,
        accessGroup: String?
    ) throws {
        let query = baseQuery(service: service, account: account, accessGroup: accessGroup)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error(status: status)
        }
    }
}

/// Keeps the Supabase session in the data-protection keychain (team-scoped
/// access group), so the auth item is prompt-free and durable across rebuilds.
///
/// This replaces the earlier login-keychain storage. Switching keychains is a
/// one-way move: a session that lived only in the old login keychain is not
/// migrated (the old item was the source of the recurring prompt), so an
/// existing user signs in once after this ships.
private struct UniversalIOAuthLocalStorage: AuthLocalStorage {
    static let storageKey = "com.universal-io.mac.auth.skcsbcyivjcvevxntvqa"

    private static let service = "com.universal-io.mac.supabase"
    // No explicit access group: avoids the keychain-access-groups entitlement
    // (and thus a provisioning profile) while still using the prompt-free
    // data-protection keychain.
    private static let accessGroup: String? = nil

    // Safety net: if this build is ever denied the data-protection keychain
    // (errSecMissingEntitlement), fall back to the SDK's login-keychain storage
    // so auth still works — no worse than before this change. Expected to stay
    // unused on a normally signed build.
    private let fileFallback = KeychainLocalStorage(service: service)

    func store(key: String, value: Data) throws {
        do {
            try DataProtectionKeychain.set(
                value, service: Self.service, account: key, accessGroup: Self.accessGroup
            )
        } catch let error as DataProtectionKeychain.Error
            where error.status == errSecMissingEntitlement {
            Self.logFallback("store")
            try fileFallback.store(key: key, value: value)
        }
    }

    func retrieve(key: String) throws -> Data? {
        do {
            return try DataProtectionKeychain.get(
                service: Self.service, account: key, accessGroup: Self.accessGroup
            )
        } catch let error as DataProtectionKeychain.Error
            where error.status == errSecMissingEntitlement {
            Self.logFallback("retrieve")
            return try? fileFallback.retrieve(key: key)
        }
    }

    func remove(key: String) throws {
        try? DataProtectionKeychain.delete(
            service: Self.service, account: key, accessGroup: Self.accessGroup
        )
        // Clear the fallback backend too, so sign-out leaves nothing behind
        // regardless of which one holds the session.
        try? fileFallback.remove(key: key)
    }

    private static func logFallback(_ operation: String) {
        #if DEBUG
        NSLog(
            "BombSquad auth: data-protection keychain unavailable (%@); using login-keychain fallback.",
            operation
        )
        #endif
    }
}

enum BombSquadAuthError: LocalizedError {
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
