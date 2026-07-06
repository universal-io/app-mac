import Foundation
import Supabase

@MainActor
final class AuthViewModel: ObservableObject {
    /// App-wide auth state. The panel is summoned and dismissed constantly, but
    /// the session lives for the app's lifetime, so it must not be re-created per
    /// panel — doing so flashes the login screen (~0.5s) while the async initial
    /// session loads, and re-runs bootstrap/account fetches on every summon.
    static let shared = AuthViewModel()

    @Published var email: String = ""
    @Published var signedInEmail: String?
    @Published var authMethodLabel: String?
    @Published var tenantID: UUID?
    @Published var accountSummary: BombSquadAccountSummary?
    @Published var isBusy = false
    @Published var hasSession = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let authClient: BombSquadAuthClient
    private var authStateTask: Task<Void, Never>?
    private var initializedUserID: UUID?

    init(authClient: BombSquadAuthClient = .shared) {
        self.authClient = authClient
        // Seed from the synchronously-available cached session so the very first
        // render already knows whether we're logged in (no login-screen flash).
        self.hasSession = authClient.currentSession() != nil
        start()
    }

    deinit {
        authStateTask?.cancel()
    }

    var isConfigured: Bool {
        authClient.isConfigured
    }

    var canSendMagicLink: Bool {
        isConfigured && !isBusy && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSignInWithGoogle: Bool {
        isConfigured && !isBusy
    }

    func sendMagicLink() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil

        Task {
            do {
                try await authClient.sendMagicLink(email: email)
                await MainActor.run {
                    self.email = self.email.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = "ログイン用メールを送信しました。この Mac でメール内のリンクを開いてください。"
                    self.isBusy = false
                }
            } catch {
                await present(error)
                await MainActor.run {
                    self.isBusy = false
                }
            }
        }
    }

    func signInWithGoogle() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil

        Task {
            do {
                let session = try await authClient.signInWithGoogle()
                try await refreshState(session: session, shouldBootstrap: true)
                await MainActor.run {
                    self.statusMessage = "Google でログインしました。"
                    self.isBusy = false
                }
            } catch {
                await present(error)
                await MainActor.run {
                    self.isBusy = false
                }
            }
        }
    }

    func signOut() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        statusMessage = nil

        Task {
            do {
                try await authClient.signOut()
                GatewayQuotaStore.shared.clear()
                await MainActor.run {
                    self.initializedUserID = nil
                    self.tenantID = nil
                    self.accountSummary = nil
                    self.signedInEmail = nil
                    self.hasSession = false
                    self.statusMessage = "ログアウトしました。"
                    self.isBusy = false
                }
            } catch {
                await present(error)
                await MainActor.run {
                    self.isBusy = false
                }
            }
        }
    }

    private func start() {
        authStateTask = Task { [weak self] in
            guard let self else { return }
            for await change in authClient.authStateChanges() {
                if Task.isCancelled { break }
                await self.handleAuthStateChange(change)
            }
        }
    }

    private func handleAuthStateChange(_ change: BombSquadAuthClient.AuthStateChange) async {
        NSLog("BombSquad sync: auth event %@ (session: %@)",
              String(describing: change.event), change.session == nil ? "none" : "present")
        do {
            switch change.event {
            case .initialSession:
                try await refreshState(session: change.session, shouldBootstrap: change.session != nil)
                // Normal launches restore the session asynchronously and emit
                // .initialSession (not .signedIn), after the launch-time sync
                // in MemorySyncService.start() has already no-opped without a
                // session — so this is the trigger that makes startup sync work.
                if change.session != nil {
                    Task { await MemorySyncService.shared.syncNow() }
                }
            case .signedIn:
                try await refreshState(session: change.session, shouldBootstrap: true)
                statusMessage = authMethodLabel.map { "\($0)でログインしました。" } ?? "ログインしました。"
                // Gateway access just became available (or a new user signed
                // in on this device) — sync memory right away rather than
                // waiting for the next local edit.
                Task { await MemorySyncService.shared.syncNow() }
            case .tokenRefreshed, .userUpdated, .mfaChallengeVerified, .passwordRecovery:
                try await refreshState(session: change.session, shouldBootstrap: false)
            case .signedOut, .userDeleted:
                initializedUserID = nil
                tenantID = nil
                accountSummary = nil
                signedInEmail = nil
                authMethodLabel = nil
                hasSession = false
            }
        } catch {
            await present(error)
        }
    }

    private func refreshState(session: Session?, shouldBootstrap: Bool) async throws {
        guard let session else {
            initializedUserID = nil
            tenantID = nil
            signedInEmail = nil
            authMethodLabel = nil
            hasSession = false
            return
        }

        hasSession = true
        signedInEmail = session.user.email ?? authClient.currentUserEmail()
        authMethodLabel = authMethodLabel(for: session)
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let signedInEmail {
            email = signedInEmail
        }

        if shouldBootstrap && initializedUserID != session.user.id {
            tenantID = try await authClient.bootstrapCurrentUser()
            initializedUserID = session.user.id
        }

        accountSummary = try await fetchAccountSummary()
    }

    /// Refreshes the account summary (and the quota bundled with it) from the
    /// gateway. Called when the my page appears so usage is always current.
    /// Keeps the existing summary while loading and on failure (no flicker).
    func refreshAccount() async {
        guard hasSession else { return }
        do {
            accountSummary = try await fetchAccountSummary()
        } catch {
            await present(error)
        }
    }

    private func fetchAccountSummary() async throws -> BombSquadAccountSummary {
        guard let client = GatewayAccountClient.make() else {
            throw ProviderError.gateway(
                message: "アカウント情報を取得できませんでした。API の設定とログイン状態を確認してください。"
            )
        }
        return try await client.fetchAccount()
    }

    private func present(_ error: Error) async {
        await MainActor.run {
            self.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func authMethodLabel(for session: Session) -> String? {
        if let provider = session.user.appMetadata["provider"]?.stringValue {
            return providerLabel(for: provider)
        }

        if let provider = session.user.identities?.first?.provider {
            return providerLabel(for: provider)
        }

        if session.user.email != nil {
            return "メール"
        }

        return nil
    }

    private func providerLabel(for provider: String) -> String {
        switch provider.lowercased() {
        case "google":
            return "Google"
        case "apple":
            return "Apple"
        case "email":
            return "メール"
        default:
            return provider
        }
    }
}
