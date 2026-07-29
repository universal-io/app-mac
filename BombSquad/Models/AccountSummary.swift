import Foundation

/// A plan identifier from the gateway, plus how to show it.
///
/// The client keeps no list of which plans exist or what they grant: `bs_plans`
/// alone decides that (README, 課金), and the quota shown on the account page
/// comes from the gateway's own envelope. This type only names a plan for
/// display, and a plan it does not recognise is shown verbatim.
///
/// The verbatim fallback is the point. This used to be a three-case enum
/// (free / individual / business) mapping anything unknown onto `.free`, so when
/// `standard` was added to `bs_plans` and sold, the account page told a paying
/// subscriber they were on the free plan. Adding a row to `bs_plans` must never
/// again be able to make the app misreport what someone bought.
struct BombSquadPlan: Equatable {
    let id: String

    var label: String {
        switch id {
        case "free": return "フリー"
        case "standard": return "スタンダード"
        case "pro": return "プロ"
        case "team": return "チーム"
        case "enterprise": return "エンタープライズ"
        default: return id
        }
    }

    /// Whether this is anything other than the free tier. Says nothing about
    /// which paid plans exist, only that this one is not the free one.
    var isPaid: Bool { id != "free" }
}

enum BombSquadAccountState: String {
    case trialing
    case active
    case pastDue = "past_due"
    case canceled
    case suspended

    var label: String {
        switch self {
        case .trialing: return "トライアル"
        case .active: return "有効"
        case .pastDue: return "支払い確認中"
        case .canceled: return "解約済み"
        case .suspended: return "停止中"
        }
    }

    static func fromRawValue(_ value: String) -> BombSquadAccountState {
        BombSquadAccountState(rawValue: value) ?? .active
    }
}

/// Timestamps as the gateway sends them, and as this app shows them.
///
/// Shared because more than one screen prints the same kind of date and they must
/// agree. The parse tries fractional seconds first: the gateway emits JavaScript
/// `toISOString()`, which the plain ISO 8601 formatter rejects.
enum GatewayTimestamp {
    static func date(from iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    }

    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    /// Formats a gateway timestamp, falling back to the raw string so an
    /// unparseable value is still shown rather than silently dropped.
    static func dayText(fromISO iso: String) -> String {
        guard let date = date(from: iso) else { return iso }
        return dayText(date)
    }
}

struct BombSquadAccountSummary: Equatable {
    let email: String
    let tenantID: UUID
    let plan: BombSquadPlan
    let state: BombSquadAccountState
    let monthlyReviewLimit: Int
    /// Whether the gateway can open a Stripe customer portal for this account.
    /// False for an account that has never had a Stripe customer, so the app can
    /// omit a payment-management button that could only report its own absence.
    let hasBillingAccount: Bool
    /// When the plan is scheduled to end, or nil when it renews.
    ///
    /// Cancelling takes effect at the end of the paid period, so a cancelled
    /// subscriber legitimately keeps `plan: standard` / `state: active` for weeks.
    /// This is the only field that distinguishes that from an ordinary renewal —
    /// without showing it, someone who just cancelled sees "有効" and no sign that
    /// it worked.
    let cancelAt: Date?

    /// The scheduled end of the plan, formatted, or nil when it renews.
    var cancelAtText: String? {
        cancelAt.map(GatewayTimestamp.dayText)
    }
}
