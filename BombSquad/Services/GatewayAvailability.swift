import Foundation

/// Whether the gateway is refusing this account's requests right now, and the
/// one sentence to say about it.
///
/// Every AI route answers GET with the same auth and quota preflight the real
/// request would run, and the app already calls it on launch and again before
/// each operation to warm the function. So when the month is spent, the answer
/// is in the app's hands before the user has typed anything — it was simply
/// discarded (`_ = try? await client.get(…)`), leaving them to find out by
/// having something fail. A tool that knows it cannot work owes that sentence
/// up front, not as the result of an attempt.
///
/// One observer, one sentence, one view. The condition is a property of the
/// account rather than of a feature, so every surface reads the same value
/// instead of each one detecting it again — the detection lives in
/// `GatewayClient.send`, the single point every request already passes through.
final class GatewayAvailability: ObservableObject {
    static let shared = GatewayAvailability()

    /// Ready-to-show text, or nil while nothing is standing in the way.
    @Published private(set) var refusal: String?

    /// Refusals that will refuse the next request too.
    ///
    /// A provider outage, a rate limit and a dropped connection all resolve by
    /// themselves, and a standing banner for those would outlive the condition
    /// it describes — which is worse than saying nothing, because the user
    /// stops believing the banner.
    private static let standing: Set<String> = [
        "QUOTA_EXCEEDED",
        "SERVICE_CAPACITY_REACHED",
        "PAYMENT_REQUIRED",
        "UNAUTHENTICATED",
    ]

    private init() {}

    /// The sentence to keep standing, or nil when the failure says nothing
    /// about whether the next request can succeed.
    ///
    /// Pure, and separate from the store, because this one rule is the whole
    /// component: which failures are worth telling someone about before they
    /// try. Everything else here is plumbing.
    static func standingRefusal(in error: Error) -> String? {
        guard
            case let .gateway(message, code)? = error as? ProviderError,
            let code,
            standing.contains(code)
        else { return nil }
        return message
    }

    /// Records what a failed request revealed about the account's standing.
    /// Transient failures leave the current value alone.
    func observe(_ error: Error) {
        guard let refusal = Self.standingRefusal(in: error) else { return }
        publish(refusal)
    }

    /// A request got through, so whatever was standing in the way is not.
    func observeSuccess() {
        publish(nil)
    }

    /// Signing out ends the account this value described.
    func clear() {
        publish(nil)
    }

    private func publish(_ value: String?) {
        DispatchQueue.main.async {
            guard self.refusal != value else { return }
            self.refusal = value
        }
    }
}
