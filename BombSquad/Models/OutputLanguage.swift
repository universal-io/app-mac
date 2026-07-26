import Foundation

/// The language the deliverable is written in — the draft to send, the summary
/// of a received message, the answer about the screen. Selecting one makes the
/// result come out in it regardless of the input language (e.g. write Japanese
/// → send English; scan Chinese → read Japanese).
///
/// This is not the language of the app's own interface, which is Japanese
/// everywhere for now.
enum OutputLanguage: String, CaseIterable, Identifiable {
    case japanese
    case english

    var id: String { rawValue }

    /// What a first launch should pick. Read from the Mac rather than assumed:
    /// hardcoding Japanese was a guess that happened to be right for the person
    /// who wrote it, and wrong for everyone whose Mac says otherwise.
    static var systemDefault: OutputLanguage {
        let preferred = Locale.preferredLanguages.first ?? Locale.current.identifier
        let code = Locale(identifier: preferred).language.languageCode?.identifier
        return code == "ja" ? .japanese : .english
    }

    /// Shown in the picker.
    var displayName: String {
        switch self {
        case .japanese: return "日本語"
        case .english: return "English"
        }
    }

    /// Language name injected into the prompt instruction.
    var promptName: String {
        switch self {
        case .japanese: return "日本語"
        case .english: return "英語"
        }
    }
}
