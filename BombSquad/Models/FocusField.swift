import Foundation

/// Which editor currently has focus. Drives the blue focus highlight and
/// determines which side gets deployed.
enum FocusField: Hashable {
    case draft     // top: original
    case revision  // bottom: review result
    case navigator // vision panel: navigator question input
}
