import CoreGraphics
import Foundation
import PDFVisualDiff

/// The page size of the filled form.
public enum PageMode: String, Sendable, CaseIterable {
    /// Exact A4 (210 × 297 mm). A near-A4 original keeps its top-left corner
    /// and loses only the blank strip beyond A4; it is never scaled.
    case a4
    /// The original page's own size.
    case original
}

/// Stamps a compiled overlay onto a copy of a one-page blank form.
public enum FormStamper {
    /// Resolution used to look for ink in the strip removed by A4 normalization.
    static let stripCheckDPI = 288.0

    /// Writes a new single-page PDF to `output`: the original page drawn 1:1
    /// with its top-left corner at the new page's top-left corner, then the
    /// overlay page drawn 1:1 the same way. Neither is scaled. The original
    /// file is only read. On error nothing is written to `output`.
    public static func stamp(original: URL, overlay: URL, pageMode: PageMode = .a4, output: URL) throws {
        let page = try singlePage(original, isOriginal: true)
        let box = page.getBoxRect(.cropBox)

        let target: CGSize
        switch pageMode {
        case .original:
            target = box.size
        case .a4:
            guard PageGeometry.classify(box.size) != .other else {
                throw FormFillError.notNearA4(width: Double(box.width), height: Double(box.height))
            }
            let ink = try PageGeometry.inkInRemovedStrip(page: page, target: PageGeometry.a4, dpi: stripCheckDPI)
            guard ink == 0 else { throw FormFillError.inkInRemovedStrip(pixels: ink) }
            target = PageGeometry.a4
        }

        let overlayPage = try singlePage(overlay, isOriginal: false)
        let overlayBox = overlayPage.getBoxRect(.cropBox)

        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".\(output.lastPathComponent).\(UUID().uuidString).tmp")
        var mediaBox = CGRect(origin: .zero, size: target)
        guard let context = CGContext(temporary as CFURL, mediaBox: &mediaBox, nil) else {
            throw FormFillError.outputWriteFailed(output.path)
        }
        context.beginPDFPage(nil)
        for (source, sourceBox) in [(page, box), (overlayPage, overlayBox)] {
            context.saveGState()
            // Map the source's top-left corner onto the target's top-left corner.
            context.translateBy(x: -sourceBox.minX, y: target.height - sourceBox.maxY)
            context.drawPDFPage(source)
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()

        do {
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: output)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw FormFillError.outputWriteFailed(output.path)
        }
    }

    private static func singlePage(_ url: URL, isOriginal: Bool) throws -> CGPDFPage {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw FormFillError.unreadablePDF(url.path)
        }
        guard document.numberOfPages > 0 else { throw FormFillError.emptyPDF(url.path) }
        guard document.numberOfPages == 1, let page = document.page(at: 1) else {
            throw isOriginal ? FormFillError.multiPageOriginal(pages: document.numberOfPages)
                             : FormFillError.overlayPageCount(document.numberOfPages)
        }
        return page
    }
}
