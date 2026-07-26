import Foundation

/// One thing the app may remember about the user, in one place it may remember
/// it. The vocabulary is fixed by the skills on the gateway, so a slot exists
/// whether or not it has been filled — the list is meant to show what the app
/// is able to learn, not only what it happens to know.
///
/// `scope` is "global" or the id of the skill that declared the key.
struct UserFact: Identifiable, Equatable {
    let scope: String
    let scopeLabel: String
    let key: String
    let label: String
    /// Nil while the slot is empty. Never a blank string: clearing a value is a
    /// deletion, which is the same thing the user means by emptying the field.
    var value: String?
    var updatedAt: Date?

    var id: String { "\(scope)/\(key)" }
    var isLearned: Bool { !(value ?? "").isEmpty }
}

/// A fact the screen appeared to establish, offered for confirmation before
/// anything is stored. The gateway writes the sentence — the value inside it
/// came off a screen we do not control, so the app never assembles copy around
/// it — and this app only shows it and reports the answer.
struct FactQuestion: Equatable {
    let scope: String
    let key: String
    /// The value read off the screen, already normalized and quoted inside
    /// `question`. Kept separately because saying yes stores exactly this.
    let value: String
    /// Ready-to-show Japanese sentence, e.g. 「Slackでの表示名は「…」ですか？」.
    let question: String
}

/// What has happened to the confirmation question in this session. Answering is
/// terminal in both directions: yes stores the fact, no retires the key for
/// good, and neither is asked again.
enum FactQuestionState: Equatable {
    case asking
    case saving
    case saved
    case declined
    case failed(String)
}

/// The facts grouped the way they are shown: global first, then one section per
/// tool, each in the order the gateway declared them.
struct UserFactGroup: Identifiable, Equatable {
    let scope: String
    let label: String
    var facts: [UserFact]

    var id: String { scope }
    var learnedCount: Int { facts.filter(\.isLearned).count }
}
