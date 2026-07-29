import AppKit
import Foundation
import Supabase

@MainActor
final class AuthViewModel: ObservableObject {
    /// App-wide auth state. The panel is summoned and dismissed constantly, but
    /// the session lives for the app's lifetime, so it must not be re-created per
    /// panel — doing so flashes the login screen (~0.5s) while the async initial
    /// session loads, and re-runs bootstrap/account fetches on every summon.
    static let shared = AuthViewModel(startImmediately: !AppRuntime.isRunningUnitTests)

    @Published var email: String = ""
    @Published var signedInEmail: String?
    @Published var authMethodLabel: String?
    @Published var tenantID: UUID?
    @Published var accountSummary: BombSquadAccountSummary?
    @Published var isBusy = false
    @Published var hasSession = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    /// The raw underlying error, shown small beneath `errorMessage`. Only ever
    /// set alongside a friendly `errorMessage`.
    @Published var errorDetail: String?
    /// A neutral, non-alarming note (e.g. after the user cancels Google
    /// sign-in). Shown in secondary style, never red.
    @Published var infoMessage: String?
    /// Billing-portal state, kept separate from the auth messages above so the
    /// pricing section reports its own outcome and an old sign-in error never
    /// surfaces next to a payment button.
    @Published var isOpeningBillingPortal = false
    @Published var billingErrorMessage: String?

    private lazy var authClient = BombSquadAuthClient.shared
    private var authStateTask: Task<Void, Never>?
    private var initializedUserID: UUID?

    init(startImmediately: Bool = true) {
        guard startImmediately else { return }
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
        errorDetail = nil
        infoMessage = nil
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
        errorDetail = nil
        infoMessage = nil
        statusMessage = nil

        Task {
            do {
                let session = try await authClient.signInWithGoogle()
                try await refreshState(
                    session: session,
                    shouldBootstrap: true,
                    migrateLegacyData: false
                )
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
        errorDetail = nil
        infoMessage = nil
        statusMessage = nil

        Task {
            do {
                try await authClient.signOut()
                try await self.activateLocalAccount(userID: nil, migrateLegacyData: false)
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

    /// Opens the Stripe customer portal in the browser.
    ///
    /// This is the only route out of a paid plan: cancellation, payment-method
    /// changes and invoices all live on Stripe's screens, and the app has no
    /// business rebuilding them. Without this the app could sell a subscription
    /// it gave the user no way to stop.
    func openBillingPortal() {
        guard !isOpeningBillingPortal else { return }
        guard let client = GatewayBillingClient.make() else {
            billingErrorMessage =
                "お支払い管理を開けませんでした。ログイン状態を確認してください。"
            return
        }
        isOpeningBillingPortal = true
        billingErrorMessage = nil

        Task {
            do {
                let url = try await client.portalURL()
                await MainActor.run {
                    NSWorkspace.shared.open(url)
                    self.isOpeningBillingPortal = false
                }
            } catch {
                await MainActor.run {
                    // Shown in place rather than through `present`: the gateway's
                    // own message (e.g. "お支払い情報がまだありません。") is the
                    // useful text here.
                    self.billingErrorMessage = UserFacingError.message(for: error)
                    self.isOpeningBillingPortal = false
                }
            }
        }
    }

    func deleteAccount() {
        guard !isBusy,
              let userID = authClient.currentUserID(),
              let client = GatewayAccountClient.make()
        else { return }
        isBusy = true
        errorMessage = nil
        errorDetail = nil
        infoMessage = nil
        statusMessage = nil

        Task {
            do {
                try await client.deleteAccount()

                // Close SQLite handles before deleting the account directory.
                AppSupport.markAccountForDeletion(userID)
                var localCleanupFailed = false
                do {
                    try await self.activateLocalAccount(userID: nil, migrateLegacyData: false)
                } catch {
                    localCleanupFailed = true
                }
                FoundationComposeDraftStore.removeAccountData(userID: userID)
                do {
                    try AppSupport.removeAccountDirectory(for: userID)
                    AppSupport.clearPendingAccountDeletion(userID)
                } catch {
                    localCleanupFailed = true
                }
                ScreenshotCaptureService.cleanupTemporaryCaptures()
                try? await authClient.signOut()
                GatewayQuotaStore.shared.clear()

                await MainActor.run {
                    self.initializedUserID = nil
                    self.tenantID = nil
                    self.accountSummary = nil
                    self.signedInEmail = nil
                    self.authMethodLabel = nil
                    self.hasSession = false
                    if localCleanupFailed {
                        self.statusMessage = nil
                        self.errorDetail = nil
                        self.errorMessage = "アカウントは削除されました。このMacのローカルデータは次回起動時に消去を再試行します。"
                    } else {
                        self.statusMessage = "アカウントと、このMacに保存された関連データを削除しました。"
                    }
                    self.isBusy = false
                }
            } catch {
                await present(error)
                await MainActor.run { self.isBusy = false }
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
                try await refreshState(
                    session: change.session,
                    shouldBootstrap: change.session != nil,
                    migrateLegacyData: change.session != nil
                )
            case .signedIn:
                try await refreshState(
                    session: change.session,
                    shouldBootstrap: true,
                    migrateLegacyData: false
                )
                statusMessage = authMethodLabel.map { "\($0)でログインしました。" } ?? "ログインしました。"
            case .tokenRefreshed, .userUpdated, .mfaChallengeVerified, .passwordRecovery:
                try await refreshState(
                    session: change.session,
                    shouldBootstrap: false,
                    migrateLegacyData: false
                )
            case .signedOut, .userDeleted:
                try await activateLocalAccount(userID: nil, migrateLegacyData: false)
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

    private func refreshState(
        session: Session?,
        shouldBootstrap: Bool,
        migrateLegacyData: Bool
    ) async throws {
        guard let session else {
            try await activateLocalAccount(userID: nil, migrateLegacyData: false)
            initializedUserID = nil
            tenantID = nil
            signedInEmail = nil
            authMethodLabel = nil
            hasSession = false
            return
        }

        try await activateLocalAccount(
            userID: session.user.id,
            migrateLegacyData: migrateLegacyData
        )
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

    private func activateLocalAccount(
        userID: UUID?,
        migrateLegacyData: Bool
    ) async throws {
        FoundationComposeDraftStore.activateAccount(
            userID: userID,
            migrateLegacyDraft: migrateLegacyData
        )
        try await LocalHistoryStore.shared.activateAccount(
            userID: userID,
            migrateLegacyDatabase: migrateLegacyData
        )
    }

    /// Refreshes the account summary (and the quota bundled with it) from the
    /// gateway. Called when the account page appears so usage is always current.
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
            if UserFacingError.isUserCancellation(error) {
                // Backing out of the sign-in sheet is intentional, not a
                // failure. Guide the retry instead of alarming with red.
                self.errorMessage = nil
                self.errorDetail = nil
                self.infoMessage =
                    "ログインを中断しました。もう一度「Google で続ける」を押すと、アカウントを選び直せます。"
            } else if error is AuthError {
                // Supabase's AuthError is a LocalizedError carrying an English
                // string (e.g. "invalid request: both auth code and code
                // verifier should be non-empty"). Never show that as the main
                // message — a friendly line, with the raw text kept small.
                self.errorMessage = "ログインに失敗しました。時間をおいて、もう一度お試しください。"
                self.errorDetail = (error as NSError).localizedDescription
                self.infoMessage = nil
            } else {
                self.errorMessage = UserFacingError.message(for: error)
                self.errorDetail = UserFacingError.technicalDetail(for: error)
                self.infoMessage = nil
            }
        }
    }

    private func authMethodLabel(for session: Session) -> String? {
        // Show the account's actually-linked identities, not
        // app_metadata.provider — that field holds only the FIRST provider used,
        // so an account created with email and later linked to Google would keep
        // reading "email" even after a Google sign-in. Deduplicated, joined.
        let providers = session.user.identities?.map(\.provider) ?? []
        if !providers.isEmpty {
            var seen = Set<String>()
            let labels = providers
                .map(providerLabel(for:))
                .filter { seen.insert($0).inserted }
            return labels.joined(separator: "・")
        }

        if let provider = session.user.appMetadata["provider"]?.stringValue {
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
