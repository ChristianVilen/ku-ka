import CoreGraphics
import CryptoKit
import Foundation

/// What was on the pasteboard: plain text (with optional rich flavors), or
/// an image.
enum ClipboardItemKind: Equatable {
    case text(plain: String, rtf: Data?, html: Data?)
    case image(png: Data, pixelSize: CGSize)
}

/// One recorded clipboard entry. Pure value type: no AppKit, no pasteboard
/// access. `contentHash` is the dedupe key `ClipboardHistory` matches on, and
/// is computed the same way here and in the pasteboard adapter so the two
/// agree on identity.
struct ClipboardItem: Equatable {
    let kind: ClipboardItemKind
    let contentHash: String
    let copiedAt: Date

    /// One line for the panel row: the text collapsed to a single line and
    /// length-capped, or "Image WIDTH×HEIGHT" for images. Built once, up
    /// front, by the factory methods below — never recomputed on read,
    /// since the search filter re-evaluates this for every item on every
    /// keystroke, and a multi-megabyte paste is too expensive to re-scan
    /// that often.
    let previewLabel: String

    /// True only for text carrying an RTF or HTML flavor. Decides whether
    /// pasting shows the "with/without formatting" chooser.
    var hasRichFlavors: Bool {
        switch kind {
        case .text(_, let rtf, let html):
            return rtf != nil || html != nil
        case .image:
            return false
        }
    }

    /// Image PNG byte count; 0 for text. Feeds `ClipboardHistory`'s image
    /// byte budget.
    var byteCost: Int {
        switch kind {
        case .text:
            return 0
        case .image(let png, _):
            return png.count
        }
    }
}

extension ClipboardItem {
    /// How much of the raw text we look at before collapsing whitespace.
    /// Bounded so a multi-megabyte paste doesn't get fully scanned just to
    /// build a one-line preview.
    private static let previewSourceBudget = 2_000

    /// Final preview label length cap. The search filter matches against
    /// this capped label, so only the first ~500 characters of a very long
    /// paste are searchable — accepted v1 trade-off.
    private static let previewLabelMaxLength = 500

    /// Builds a text item, computing its content hash from the plain-text
    /// UTF-8 bytes and its preview label once, up front.
    static func text(plain: String, rtf: Data? = nil, html: Data? = nil, copiedAt: Date) -> ClipboardItem {
        ClipboardItem(
            kind: .text(plain: plain, rtf: rtf, html: html),
            contentHash: hash(utf8: plain),
            copiedAt: copiedAt,
            previewLabel: oneLineLabel(plain)
        )
    }

    /// Builds an image item, computing its content hash from the PNG bytes.
    static func image(png: Data, pixelSize: CGSize, copiedAt: Date) -> ClipboardItem {
        ClipboardItem(
            kind: .image(png: png, pixelSize: pixelSize),
            contentHash: hash(bytes: png),
            copiedAt: copiedAt,
            previewLabel: "Image \(Int(pixelSize.width))×\(Int(pixelSize.height))"
        )
    }

    /// SHA-256 hex digest (lowercase) of a string's UTF-8 bytes.
    static func hash(utf8 string: String) -> String {
        hash(bytes: Data(string.utf8))
    }

    /// SHA-256 hex digest (lowercase) of raw bytes.
    static func hash(bytes data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Takes a bounded prefix of `text` first (cheap even for a huge
    /// paste), then collapses whitespace/newlines to single spaces and
    /// trims, then caps the result to `previewLabelMaxLength`.
    private static func oneLineLabel(_ text: String) -> String {
        let boundedPrefix = String(text.prefix(previewSourceBudget))
        let collapsed = boundedPrefix
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(previewLabelMaxLength))
    }
}
