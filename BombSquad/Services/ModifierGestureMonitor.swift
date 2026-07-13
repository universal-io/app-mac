import AppKit

/// Distinguishes gestures on the user-configurable gesture key
/// (`KeybindingSettings.gestureKey()`, default: Right Shift), globally and
/// within the app:
/// - single-tap  → switch editor focus
/// - double-tap  → "next" (summon / review / deploy)
/// - long-press  → hold-to-talk dictation (began on hold, ended on release)
///
/// Right Shift is the default because the Command key conflicts with everyday
/// shortcuts (⌘C/⌘V/…): merely holding ⌘ before a shortcut would fire the
/// gesture. Only modifier keys qualify as gesture keys — an ordinary key
/// would insert characters unless suppressed with a CGEventTap.
///
/// The monitors observe every `flagsChanged` event and read the configured
/// key per event, so a settings change takes effect immediately without
/// re-registration. A gesture is only recognized when the key is pressed
/// without any other modifier; pressing another key (e.g. typing a capital
/// letter) cancels the pending gesture.
/// Requires Accessibility permission (already requested for paste injection).
final class ModifierGestureMonitor {
    var onSingleTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onLongPressBegan: (() -> Void)?
    var onLongPressEnded: (() -> Void)?

    private var lastTapTime: TimeInterval = 0
    private var keyDownClean = false
    private var isLongPressing = false
    private var longPressWork: DispatchWorkItem?
    private var singleTapWork: DispatchWorkItem?
    private var monitors: [Any] = []
    private var trustPollTimer: Timer?
    /// First few received events are logged to diagnose the intermittent
    /// "gestures dead right after launch" report (master plan M1 known bug).
    private var diagnosticLogBudget = 6

    func start() {
        let trusted = AccessibilityPermission.isTrusted
        NSLog("BombSquad gesture: monitors starting (AX trusted: %@)", trusted ? "yes" : "no")
        registerMonitors()

        // Global event monitors registered while the app is not yet trusted for
        // Accessibility never start delivering events, even after the user
        // grants the permission — the first launch would need an app restart.
        // Watch for the grant and re-register once it arrives.
        guard !trusted else { return }
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard AccessibilityPermission.isTrusted else { return }
            timer.invalidate()
            self.trustPollTimer = nil
            NSLog("BombSquad gesture: accessibility granted; re-registering monitors")
            self.removeMonitors()
            self.registerMonitors()
        }
    }

    private func registerMonitors() {
        let flags: (NSEvent) -> Void = { [weak self] in self?.handleFlags($0) }
        let keys: (NSEvent) -> Void = { [weak self] _ in self?.invalidatePending() }

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { keys($0); return $0 } as Any)
    }

    private func removeMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    private func handleFlags(_ event: NSEvent) {
        let key = KeybindingSettings.gestureKey()
        if diagnosticLogBudget > 0 {
            diagnosticLogBudget -= 1
            NSLog("BombSquad gesture: flagsChanged received (keyCode %d, %@ %@)",
                  event.keyCode, key.rawValue,
                  event.modifierFlags.contains(key.modifierFlag) ? "down" : "up")
        }
        guard event.keyCode == key.keyCode else {
            // Another modifier changed → not a clean gesture-key press.
            invalidatePending()
            return
        }

        if event.modifierFlags.contains(key.modifierFlag) {
            // Pressed: clean only if no other modifier is held.
            let others = GestureKey.allModifierFlags.subtracting(key.modifierFlag)
            keyDownClean = event.modifierFlags.isDisjoint(with: others)
            if keyDownClean { scheduleLongPress() }
        } else {
            // Released.
            longPressWork?.cancel()
            longPressWork = nil
            if isLongPressing {
                isLongPressing = false
                onLongPressEnded?()
            } else if keyDownClean {
                let now = event.timestamp
                if now - lastTapTime <= KeybindingSettings.doubleTapThreshold() {
                    singleTapWork?.cancel()
                    singleTapWork = nil
                    lastTapTime = 0
                    onDoubleTap?()
                } else {
                    lastTapTime = now
                    scheduleSingleTap()
                }
            }
            keyDownClean = false
        }
    }

    private func scheduleLongPress() {
        longPressWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.keyDownClean, !self.isLongPressing else { return }
            self.isLongPressing = true
            self.onLongPressBegan?()
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + KeybindingSettings.longPressThreshold(),
            execute: work
        )
    }

    private func scheduleSingleTap() {
        singleTapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lastTapTime = 0
            self.onSingleTap?()
        }
        singleTapWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + KeybindingSettings.doubleTapThreshold(),
            execute: work
        )
    }

    /// A non-modifier key was pressed → cancel any pending tap/long-press.
    /// Does not stop an already-running dictation (isLongPressing stays true).
    private func invalidatePending() {
        keyDownClean = false
        lastTapTime = 0
        longPressWork?.cancel()
        longPressWork = nil
        singleTapWork?.cancel()
        singleTapWork = nil
    }
}
