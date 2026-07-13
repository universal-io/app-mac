import AppKit

/// The modifier key that drives the tap / double-tap / long-press gestures.
/// Only modifier keys qualify: an ordinary key would insert characters unless
/// suppressed with a CGEventTap, which is too invasive for a resident app.
enum GestureKey: String, CaseIterable, Identifiable {
    case rightShift
    case leftShift
    case rightOption
    case leftOption
    case rightControl
    case leftControl
    case rightCommand
    case leftCommand
    case fn

    var id: String { rawValue }

    /// Physical key code delivered in `flagsChanged` events.
    var keyCode: UInt16 {
        switch self {
        case .rightShift: return 60
        case .leftShift: return 56
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightControl: return 62
        case .leftControl: return 59
        case .rightCommand: return 54
        case .leftCommand: return 55
        case .fn: return 63
        }
    }

    /// The modifier flag that indicates this key is held down. Left/right
    /// pairs share one flag; the key code disambiguates the side.
    var modifierFlag: NSEvent.ModifierFlags {
        switch self {
        case .rightShift, .leftShift: return .shift
        case .rightOption, .leftOption: return .option
        case .rightControl, .leftControl: return .control
        case .rightCommand, .leftCommand: return .command
        case .fn: return .function
        }
    }

    /// Every flag a gesture key can own. A press is "clean" only when no
    /// *other* of these flags is held at the same time.
    static let allModifierFlags: NSEvent.ModifierFlags =
        [.shift, .command, .option, .control, .function]

    var displayName: String {
        switch self {
        case .rightShift: return "右 Shift"
        case .leftShift: return "左 Shift"
        case .rightOption: return "右 Option"
        case .leftOption: return "左 Option"
        case .rightControl: return "右 Control"
        case .leftControl: return "左 Control"
        case .rightCommand: return "右 ⌘"
        case .leftCommand: return "左 ⌘"
        case .fn: return "fn（🌐）"
        }
    }

    /// Compact label for in-panel shortcut hints (e.g. "右Shift ×2").
    var hintLabel: String {
        switch self {
        case .rightShift: return "右Shift"
        case .leftShift: return "左Shift"
        case .rightOption: return "右Option"
        case .leftOption: return "左Option"
        case .rightControl: return "右Control"
        case .leftControl: return "左Control"
        case .rightCommand: return "右⌘"
        case .leftCommand: return "左⌘"
        case .fn: return "fn"
        }
    }

    /// Shown under the picker when the choice needs a caveat.
    var caution: String? {
        switch self {
        case .rightCommand, .leftCommand:
            return "⌘ は日常のショートカット（⌘C/⌘V など）と同時に押されやすく、"
                + "誤動作の恐れがあります。ご注意ください。"
        case .fn:
            return "システム設定 → キーボード の「🌐キーを押して」を「何もしない」にしてください。"
                + "絵文字入力や入力ソース切替が割り当たっているとそちらが優先されます。"
                + "一部の外部キーボードでは fn がシステムに届かない場合があります。"
        default:
            return nil
        }
    }
}

/// Keyboard binding preferences. Stored locally in UserDefaults for now;
/// account-level sync through the Gateway is a planned later phase.
enum KeybindingSettings {
    static let gestureKeyKey = "keybinding.gestureKey"
    static let doubleTapThresholdMsKey = "keybinding.doubleTapThresholdMs"
    static let longPressThresholdMsKey = "keybinding.longPressThresholdMs"

    static let defaultGestureKey: GestureKey = .rightShift
    static let defaultDoubleTapThresholdMs = 350
    static let defaultLongPressThresholdMs = 300

    /// Read per event by the gesture monitor, so changes apply immediately
    /// without re-registering the NSEvent monitors.
    static func gestureKey() -> GestureKey {
        let stored = UserDefaults.standard.string(forKey: gestureKeyKey)
        return stored.flatMap(GestureKey.init(rawValue:)) ?? defaultGestureKey
    }

    /// Max interval between two taps to count as a double-tap.
    static func doubleTapThreshold() -> TimeInterval {
        TimeInterval(doubleTapThresholdMs()) / 1000
    }

    /// Hold duration after which a press becomes hold-to-talk.
    static func longPressThreshold() -> TimeInterval {
        TimeInterval(longPressThresholdMs()) / 1000
    }

    static func doubleTapThresholdMs() -> Int {
        let stored = UserDefaults.standard.integer(forKey: doubleTapThresholdMsKey)
        return stored > 0 ? stored : defaultDoubleTapThresholdMs
    }

    static func longPressThresholdMs() -> Int {
        let stored = UserDefaults.standard.integer(forKey: longPressThresholdMsKey)
        return stored > 0 ? stored : defaultLongPressThresholdMs
    }

    /// Restores every keybinding to the factory default.
    static func resetToDefaults() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: gestureKeyKey)
        defaults.removeObject(forKey: doubleTapThresholdMsKey)
        defaults.removeObject(forKey: longPressThresholdMsKey)
    }
}
