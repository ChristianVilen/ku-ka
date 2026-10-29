import AppKit

/// Text labels for the panels and windows that Ku-Ka builds in code. A label made here can never
/// be edited or selected.
extension NSTextField {
    /// A label on one line that truncates at its end. `digits` gives every digit the same width,
    /// so a time that counts up does not move.
    static func makeLabel(size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                          digits: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// A label that wraps onto as many lines as its text needs.
    static func makeWrappingLabel(size: CGFloat, weight: NSFont.Weight = .regular,
                                  color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        return label
    }

    /// Shows `text`, or hides the label when there is no text.
    func show(_ text: String?) {
        stringValue = text ?? ""
        isHidden = text == nil
    }
}
