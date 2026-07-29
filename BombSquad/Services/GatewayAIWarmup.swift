import Foundation

/// One maintenance point for warming production AI routes. GET runs only the
/// exact serverless function's auth/quota preflight; it never invokes a model
/// or records usage. Feature sessions choose when user think-time can hide it.
enum GatewayAIWarmup {
    enum Feature: String, CaseIterable {
        case review
        case vision
        case suggest
        case transcribe

        var path: String { "ai/\(rawValue)" }
    }

    static func warm(_ features: Set<Feature>) async {
        guard let client = GatewayClient.make(), !features.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for feature in features {
                group.addTask {
                    _ = try? await client.get(feature.path)
                }
            }
        }
    }

    static func warmAll() async {
        await warm(Set(Feature.allCases))
    }
}
