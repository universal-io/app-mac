import Foundation

struct ScreenshotAttachment: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let createdAt: Date
    let pixelWidth: Int?
    let pixelHeight: Int?
    /// Where on the physical screens this capture came from, in global
    /// display coordinates (CG orientation: top-left origin). Lets a
    /// normalized box inside the image be projected back onto the live
    /// screen (POC Step 3). nil for the `screencapture -i` fallback, where
    /// the region is unknown — live highlight is simply unavailable then.
    let captureRect: CGRect?

    init(
        id: UUID = UUID(),
        url: URL,
        createdAt: Date = Date(),
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        captureRect: CGRect? = nil
    ) {
        self.id = id
        self.url = url
        self.createdAt = createdAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.captureRect = captureRect
    }

    // CGRect is not Hashable; identity is the id (one attachment per file).
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ScreenshotAttachment, rhs: ScreenshotAttachment) -> Bool {
        lhs.id == rhs.id
    }
}
