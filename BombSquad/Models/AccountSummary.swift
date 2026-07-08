import Foundation

enum BombSquadAccountTier: String {
    case free
    case individual
    case business

    var label: String {
        switch self {
        case .free: return "フリー"
        case .individual: return "個人"
        case .business: return "企業"
        }
    }

    static func fromEntitlementPlan(_ plan: String) -> BombSquadAccountTier {
        switch plan {
        case "free":
            return .free
        case "pro":
            return .individual
        case "team", "enterprise":
            return .business
        default:
            return .free
        }
    }
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

struct BombSquadAccountSummary: Equatable {
    let email: String
    let tenantID: UUID
    let tier: BombSquadAccountTier
    let state: BombSquadAccountState
    // nil = unlimited (plan carries no monthly cap; foundation-redesign-plan §5-c).
    let monthlyReviewLimit: Int?
}
