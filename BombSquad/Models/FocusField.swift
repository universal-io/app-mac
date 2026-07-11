import Foundation

/// Which editor currently owns keyboard focus inside the panel.
enum FocusField: Hashable {
    case draft
    case revision
    case navigator
}
