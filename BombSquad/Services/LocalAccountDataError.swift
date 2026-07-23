import Foundation

enum LocalAccountDataError: LocalizedError {
    case noActiveAccount

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            return "ローカルデータを開くにはログインが必要です。"
        }
    }
}
