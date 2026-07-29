import Foundation

/// Client for the account summary endpoint (GET /api/account). The gateway is
/// the single source of truth for plan / status / usage, replacing the legacy
/// client-side Supabase reads of bs_profiles and bs_entitlements.
/// Transport/error plumbing lives in `GatewayClient`.
struct GatewayAccountClient {
    private let client: GatewayClient

    static func make() -> GatewayAccountClient? {
        guard let client = GatewayClient.make() else { return nil }
        return GatewayAccountClient(client: client)
    }

    init(client: GatewayClient) {
        self.client = client
    }

    /// Fetches the account summary and publishes the bundled quota envelope to
    /// `GatewayQuotaStore`, so the my-page usage rows show without waiting for
    /// an AI operation to happen first.
    func fetchAccount() async throws -> BombSquadAccountSummary {
        let data = try await client.get("account")

        let envelope: AccountResponse
        do {
            envelope = try JSONDecoder().decode(AccountResponse.self, from: data)
        } catch {
            throw ProviderError.decoding("account response: \(error.localizedDescription)")
        }

        GatewayQuotaStore.shared.update(envelope.quota)

        return BombSquadAccountSummary(
            email: envelope.account.email ?? "",
            tenantID: envelope.account.tenantID,
            plan: BombSquadPlan(id: envelope.account.plan),
            state: .fromRawValue(envelope.account.status),
            monthlyReviewLimit: envelope.account.monthlyReviewLimit,
            hasBillingAccount: envelope.account.hasBillingAccount ?? false
        )
    }

    func deleteAccount() async throws {
        _ = try await client.postJSON(
            "account",
            method: "DELETE",
            body: ["confirmation": "DELETE"]
        )
    }
}

private struct AccountResponse: Decodable {
    struct Account: Decodable {
        // The gateway emits null when the auth provider carries no email.
        let email: String?
        let tenantID: UUID
        let plan: String
        let status: String
        let monthlyReviewLimit: Int
        // Optional so a build running against a gateway that predates this field
        // still decodes; absence means "no portal", which is the safe reading.
        let hasBillingAccount: Bool?

        private enum CodingKeys: String, CodingKey {
            case email, plan, status
            case tenantID = "tenant_id"
            case monthlyReviewLimit = "monthly_review_limit"
            case hasBillingAccount = "has_billing_account"
        }
    }

    let account: Account
    let quota: GatewayQuota
}
