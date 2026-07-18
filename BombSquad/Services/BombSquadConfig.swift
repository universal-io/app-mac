import Foundation

/// Runtime config for product-facing services that will replace local-only API
/// keys as auth and the shared backend come online.
enum BombSquadConfig {
    private static let localConfigFileName = "BombSquad.local.plist"
    private static let appSupportLocalConfigRelativePath = "BombSquad/local-config.plist"
    private static let localConfigPathInfoKey = "BOMB_SQUAD_LOCAL_CONFIG_PATH"

    struct Entry {
        let key: String
        let value: String?

        var isConfigured: Bool {
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        var redactedValue: String {
            guard let value, isConfigured else { return "未設定" }
            if value.count <= 10 { return value }
            return "\(value.prefix(6))...\(value.suffix(4))"
        }
    }

    struct Snapshot {
        let apiBaseURL: Entry
        let supabaseURL: Entry
        let supabaseAnonKey: Entry

        var hasSupabaseConfig: Bool {
            supabaseURL.isConfigured && supabaseAnonKey.isConfigured
        }

        var hasBackendConfig: Bool {
            apiBaseURL.isConfigured
        }
    }

    /// Gateway routing decided at launch. Production is the unconditional
    /// default; a development endpoint requires an explicit Debug-only mode.
    struct GatewayRoutePlan: Equatable {
        let preferredURL: URL
        let usesDevelopmentOverride: Bool
    }

    static let apiBaseURLKey = "BOMB_SQUAD_API_BASE_URL"
    static let gatewayModeKey = "BOMB_SQUAD_GATEWAY_MODE"
    static let supabaseURLKey = "BOMB_SQUAD_SUPABASE_URL"
    static let supabaseAnonKey = "BOMB_SQUAD_SUPABASE_ANON_KEY"

    /// The selected gateway URL. Debug and Release both use production unless
    /// Debug was launched with BOMB_SQUAD_GATEWAY_MODE=local.
    static func resolvedAPIBaseURL(bundle: Bundle = .main) -> String? {
        gatewayRoutePlan(bundle: bundle)?.preferredURL.absoluteString
    }

    /// The production default baked into Info.plist (never overridden).
    static func productionAPIBaseURL(bundle: Bundle = .main) -> String? {
        let value = (bundle.object(forInfoDictionaryKey: apiBaseURLKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    /// True in Debug whenever a development gateway differs from production.
    static func isUsingOverriddenGateway(bundle: Bundle = .main) -> Bool {
        gatewayRoutePlan(bundle: bundle)?.usesDevelopmentOverride == true
    }

    static func gatewayRoutePlan(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GatewayRoutePlan? {
        let localConfig = localConfigValues(bundle: bundle)
        let developmentValue = firstConfiguredValue(
            environment[apiBaseURLKey],
            localConfig[apiBaseURLKey]
        )
        return makeGatewayRoutePlan(
            developmentValue: developmentValue,
            productionValue: productionAPIBaseURL(bundle: bundle),
            developmentModeRequested: environment[gatewayModeKey]?.lowercased() == "local",
            allowsDevelopmentOverride: allowsDevelopmentGatewayOverride
        )
    }

    /// Pure routing policy kept testable. A localhost value left behind in the
    /// gitignored plist is inert unless the process explicitly opts into local
    /// mode. Explicit local mode fails closed instead of leaking into production.
    static func makeGatewayRoutePlan(
        developmentValue: String?,
        productionValue: String?,
        developmentModeRequested: Bool,
        allowsDevelopmentOverride: Bool
    ) -> GatewayRoutePlan? {
        if allowsDevelopmentOverride, developmentModeRequested {
            guard let developmentURL = configuredURL(developmentValue) else { return nil }
            return GatewayRoutePlan(preferredURL: developmentURL, usesDevelopmentOverride: true)
        }
        return configuredURL(productionValue).map {
            GatewayRoutePlan(preferredURL: $0, usesDevelopmentOverride: false)
        }
    }

    private static var allowsDevelopmentGatewayOverride: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

    private static func configuredURL(_ value: String?) -> URL? {
        guard let value = firstConfiguredValue(value) else { return nil }
        guard
            let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host != nil
        else { return nil }
        return url
    }

    private static func firstConfiguredValue(_ values: String?...) -> String? {
        values.lazy.compactMap { value -> String? in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }.first
    }

    static func snapshot(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> Snapshot {
        let localConfig = localConfigValues(bundle: bundle)
        let routePlan = makeGatewayRoutePlan(
            developmentValue: firstConfiguredValue(environment[apiBaseURLKey], localConfig[apiBaseURLKey]),
            productionValue: productionAPIBaseURL(bundle: bundle),
            developmentModeRequested: environment[gatewayModeKey]?.lowercased() == "local",
            allowsDevelopmentOverride: allowsDevelopmentGatewayOverride
        )
        return Snapshot(
            apiBaseURL: Entry(key: apiBaseURLKey, value: routePlan?.preferredURL.absoluteString),
            supabaseURL: entry(for: supabaseURLKey, localConfig: localConfig, bundle: bundle, environment: environment),
            supabaseAnonKey: entry(for: supabaseAnonKey, localConfig: localConfig, bundle: bundle, environment: environment)
        )
    }

    private static func entry(
        for key: String,
        localConfig: [String: String],
        bundle: Bundle,
        environment: [String: String]
    ) -> Entry {
        let localValue = localConfig[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let localValue, !localValue.isEmpty {
            return Entry(key: key, value: localValue)
        }

        let environmentValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let environmentValue, !environmentValue.isEmpty {
            return Entry(key: key, value: environmentValue)
        }

        let plistValue = (bundle.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let plistValue, !plistValue.isEmpty {
            return Entry(key: key, value: plistValue)
        }

        return Entry(key: key, value: nil)
    }

    private static func localConfigValues(bundle: Bundle, fileManager: FileManager = .default) -> [String: String] {
        for url in candidateLocalConfigURLs(bundle: bundle, fileManager: fileManager) {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard
                let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                let dictionary = plist as? [String: Any]
            else {
                continue
            }

            var result: [String: String] = [:]
            for (key, value) in dictionary {
                if let value = value as? String {
                    result[key] = value
                }
            }
            return result
        }

        return [:]
    }

    private static func candidateLocalConfigURLs(bundle: Bundle, fileManager: FileManager) -> [URL] {
        var urls: [URL] = []

        if let configuredPath = bundle.object(forInfoDictionaryKey: localConfigPathInfoKey) as? String {
            let trimmedPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedPath.isEmpty {
                urls.append(URL(fileURLWithPath: trimmedPath, isDirectory: false))
            }
        }

        // Bundled copy (see project.yml): the only location that does not depend
        // on the launch working directory, so it is the primary reliable source.
        if let bundledURL = bundle.url(forResource: "BombSquad.local", withExtension: "plist") {
            urls.append(bundledURL)
        }

        let workingDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        urls.append(workingDirectoryURL.appendingPathComponent(localConfigFileName))

        if let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(appSupportURL.appendingPathComponent(appSupportLocalConfigRelativePath))
        }

        return urls
    }
}
