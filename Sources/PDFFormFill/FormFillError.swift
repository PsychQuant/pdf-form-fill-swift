import Foundation

/// Errors raised by PDFFormFill. Every case names what went wrong so it can
/// be shown to a user as-is.
public enum FormFillError: Error, Equatable, CustomStringConvertible {
    case unreadablePDF(String)
    case emptyPDF(String)
    case multiPageOriginal(pages: Int)
    case engineNotFound(String)
    /// The last lines of the engine's log; the log itself is deleted with the
    /// temporary directory, since it can contain the typed text.
    case compilationFailed(logTail: String)
    case compilationTimedOut(seconds: Double)
    case invalidTimeout(Double)
    case overlayWrongSize(width: Double, height: Double, expectedWidth: Double, expectedHeight: Double)
    case overlayPageCount(Int)
    case notNearA4(width: Double, height: Double)
    case inkInRemovedStrip(pixels: Int)
    case rotatedOriginal(degrees: Int)
    case annotatedOriginal(count: Int)
    case rotatedOverlay(degrees: Int)
    case overlayInkOffPage(pixels: Int)
    case overlayTextOffPage(characters: Int)
    /// Parts of the overlay whose position cannot be determined.
    case overlayUnverifiable(parts: Int)
    case annotatedOverlay(count: Int)
    case blankFormMacroMissing(String)
    case blankFormNotFound(String)
    case unsafeBlankFormPath(String)
    case outputIsInput(path: String, role: String)
    case outputNotAFile(path: String)
    case diffArtifactCollides(path: String, role: String)
    case unreadableSource(String)
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
        case .compilationFailed(let logTail):
            return "overlay compilation failed; end of the log:\n\(logTail)"
        case .compilationTimedOut(let seconds):
            return String(format: "overlay compilation did not finish within %g seconds and was stopped", seconds)
        case .invalidTimeout(let seconds):
            return "the compile timeout must be a positive finite number of seconds, got \(seconds)"
        case let .overlayWrongSize(width, height, expectedWidth, expectedHeight):
            return String(format: "the overlay page is %.2f × %.2f bp, but the output page is %.2f × %.2f bp; "
                + "the overlay must have the output's size (A4 for page mode a4, the original's size for page mode "
                + "original), set with the geometry package", width, height, expectedWidth, expectedHeight)
        case .overlayPageCount(let pages):
            return "the overlay has \(pages) pages; it must have exactly one"
        case let .notNearA4(width, height):
            return String(format: "the original is %.2f × %.2f bp, not near A4; fill it in page mode 'original' "
                + "with an overlay of the same size (form-skeleton writes that size for such forms)", width, height)
        case .inkInRemovedStrip(let pixels):
            return "normalizing to A4 would crop \(pixels) inked pixel\(pixels == 1 ? "" : "s") of the original; "
                + "fill it in page mode 'original' with an overlay of the original's size"
        case .rotatedOriginal(let degrees):
            return "the original page is rotated by \(degrees)°; only unrotated pages are supported"
        case .annotatedOriginal(let count):
            return "the original carries \(count) annotation\(count == 1 ? "" : "s") (links, form fields or comments); "
                + "stamping redraws only the page content, so they would be lost where the pixel check cannot see it; "
                + "flatten the PDF first"
        case .rotatedOverlay(let degrees):
            return "the overlay page is rotated by \(degrees)°; only unrotated overlays are supported"
        case .overlayInkOffPage(let pixels):
            return "the overlay has \(pixels) inked pixel\(pixels == 1 ? "" : "s") outside its page, so typed text "
                + "runs past the page edge and would be cut off; move or shorten it"
        case .overlayTextOffPage(let characters):
            return "the overlay draws at \(characters) position\(characters == 1 ? "" : "s") more than half a page "
                + "off its page, where no render shows it; check the field coordinates"
        case .overlayUnverifiable(let parts):
            return "\(parts) part\(parts == 1 ? "" : "s") of the overlay cannot be placed to check for drawing off "
                + "the page (text in a font without width data, a form XObject that cannot be read to the end, "
                + "or a content stream that cannot be parsed); simplify the overlay"
        case .annotatedOverlay(let count):
            return "the overlay carries \(count) annotation\(count == 1 ? "" : "s") (links or form fields); "
                + "stamping redraws only the page content, so they would be lost; remove them from the .tex"
        case .blankFormMacroMissing(let path):
            return "no \\newcommand{\\BlankForm}{…} (or \\def\\BlankForm{…}) in \(path)"
        case .blankFormNotFound(let path):
            return "blank form not found: \(path)"
        case .unsafeBlankFormPath(let path):
            return "the blank form's path contains a character TeX would misread (\\ { } % # ^ or a control character): "
                + "\(path.debugDescription); rename the file or the folder that contains it"
        case let .outputIsInput(path, role):
            return "refusing to write the output over the \(role): \(path); choose another output path"
        case let .diffArtifactCollides(path, role):
            return "the diff artifact \(path) would replace the \(role); choose another diff directory"
        case .unreadableSource(let path):
            return "cannot read the .tex as UTF-8 text: \(path)"
        case .outputNotAFile(let path):
            return "the output exists and is not a regular file (a directory or a symbolic link): \(path); "
                + "give the path of a PDF file to write"
        case .outputWriteFailed(let path):
            return "cannot write \(path)"
        }
    }
}
