import AppKit
import AVFoundation

/// Microphone permission is required for hold-to-talk dictation (right-Shift
/// long press). Unlike Accessibility / Screen Recording, AVFoundation exposes
/// the full authorization status, so notDetermined (still promptable inline)
/// and denied (must go to System Settings) can be handled distinctly.
enum MicrophonePermission {
    static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var isDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    /// Shows the inline system prompt (only fires while notDetermined).
    static func request(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
