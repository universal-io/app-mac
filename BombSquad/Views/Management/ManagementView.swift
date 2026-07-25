import SwiftUI

/// The sections shown in the on-demand management window's sidebar.
/// The management window is the single hub for everything that is *not* the
/// lightweight capture/review panel: account, settings, history, and billing.
enum ManagementSection: String, CaseIterable, Identifiable {
    case account
    case facts
    case history
    case keyboard
    case settings
    case pricing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "アカウント"
        case .facts: return "覚えていること"
        case .keyboard: return "キーボード"
        case .settings: return "設定"
        case .history: return "履歴"
        case .pricing: return "料金プラン"
        }
    }

    var systemImage: String {
        switch self {
        case .account: return "person.crop.circle"
        case .facts: return "person.text.rectangle"
        case .keyboard: return "keyboard"
        case .settings: return "gearshape"
        case .history: return "clock.arrow.circlepath"
        case .pricing: return "creditcard"
        }
    }
}

/// Drives which section the management window shows. A shared object so the menu
/// bar, the capture panel, and AppKit window code can all point the (single)
/// management window at a specific section before bringing it to front.
@MainActor
final class ManagementNavigator: ObservableObject {
    static let shared = ManagementNavigator()
    @Published var section: ManagementSection = .account
}

/// The management window content: a modern macOS sidebar layout
/// (`NavigationSplitView`) hosting the account, settings, history, and pricing
/// sections. Opened on demand from the menu bar; never always-on, never steals
/// focus during ordinary input-support usage.
struct ManagementView: View {
    @ObservedObject private var navigator = ManagementNavigator.shared
    @ObservedObject private var authViewModel = AuthViewModel.shared
    private let config = BombSquadConfig.snapshot()

    var body: some View {
        NavigationSplitView {
            List(selection: $navigator.section) {
                Section {
                    ForEach(ManagementSection.allCases) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) {
                accountFooter
            }
        } detail: {
            detail
                .frame(minWidth: 460, minHeight: 520)
        }
        .navigationTitle("Universal I/O")
        .frame(minWidth: 720, minHeight: 560)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigator.section {
        case .account:
            AccountView(viewModel: authViewModel, config: config)
        case .facts:
            FactsView()
        case .keyboard:
            KeyboardSettingsView()
        case .settings:
            GeneralSettingsView(config: config)
        case .history:
            HistoryPlaceholderView()
        case .pricing:
            PricingView()
        }
    }

    /// At-a-glance identity at the bottom of the sidebar (Amical-style), so the
    /// signed-in account is always visible while managing settings.
    private var accountFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: authViewModel.hasSession ? "person.crop.circle.fill" : "person.crop.circle.badge.questionmark")
                .font(.title2)
                .foregroundStyle(authViewModel.hasSession ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(authViewModel.signedInEmail ?? "未ログイン")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(authViewModel.accountSummary?.tier.label ?? (authViewModel.hasSession ? "—" : "ログインしてください"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { navigator.section = .account }
    }
}
