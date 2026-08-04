import Foundation

/// The instant the user asked, and the single origin every latency number in
/// one interaction is measured from.
///
/// Pieces of the path were already timed — the AX walk, the identity
/// resolution, the gateway round trip — but each piece started its own
/// stopwatch, and several of them run *concurrently* by design (the screenshot
/// is taken beside the AX read). Adding those numbers up therefore answers no
/// question anyone asks, and none of them contains the two waits the user
/// actually experiences: the gesture-to-panel gap before any of them begins,
/// and the tail after the gateway returns.
///
/// "How long from my double-tap until I saw something" has exactly one origin.
/// This type is that origin, carried down the path so every record can say
/// where it sits relative to it.
///
/// Monotonic on purpose. A wall-clock origin reports nonsense if the system
/// clock moves, and the stall this instrumentation serves only appears in
/// processes that have been alive for days.
struct SummonClock: Sendable {
    private let origin: ContinuousClock.Instant

    init() {
        origin = ContinuousClock.now
    }

    /// Milliseconds since the user asked. Truncated, never rounded up: a
    /// reported number should never be larger than the wait that produced it.
    var elapsedMs: Int {
        let elapsed = origin.duration(to: ContinuousClock.now)
        let (seconds, attoseconds) = elapsed.components
        return Int(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }
}
