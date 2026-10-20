import Foundation

/// Errors raised by PDFFormFill. Every case names what went wrong so it can
/// be shown to a user as-is.
public enum FormFillError: Error, Equatable, CustomStringConvertible {
    case unreadablePDF(String)
    case emptyPDF(String)
    case multiPageOriginal(pages: Int)
    case engineNotFound(String)
    case compilationFailed(log: String)
    case overlayNotA4(width: Double, height: Double)
    case overlayPageCount(Int)
    case notNearA4(width: Double, height: Double)
    case inkInRemovedStrip(pixels: Int)
    case blankFormMacroMissing(String)
    case blankFormNotFound(String)
    case outputWriteFailed(String)

    public var description: String {
        switch self {
        case .unreadablePDF(let path):
            return "cannot open PDF: \(path)"
        case .emptyPDF(let path):
            return "PDF has no pages: \(path)"
        case .multiPageOriginal(let pages):
            return "the original has \(pages) pages; only single-page forms are supported"
        case .engineNotFound(let engine):
            return "TeX engine not found: \(engine)"
        case .compilationFailed(let log):
            return "overlay compilation failed; see \(log)"
        case let .overlayNotA4(width, height):
            return String(format: "the overlay page is %.2f × %.2f bp, not A4 (595.28 × 841.89 bp); use a4paper", width, height)
        case .overlayPageCount(let pages):
            return "the overlay has \(pages) pages; it must have exactly one"
        case let .notNearA4(width, height):
            return String(format: "the original is %.2f × %.2f bp, not near A4; use page mode 'original'", width, height)
        case .inkInRemovedStrip(let pixels):
            return "normalizing to A4 would crop \(pixels) inked pixel\(pixels == 1 ? "" : "s") of the original; use page mode 'original'"
        case .blankFormMacroMissing(let path):
            return "no \\newcommand{\\BlankForm}{…} (or \\def\\BlankForm{…}) in \(path)"
        case .blankFormNotFound(let path):
            return "blank form not found: \(path)"
        case .outputWriteFailed(let path):
            return "cannot write \(path)"
        }
    }
}
