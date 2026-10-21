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
    /// overlay page drawn 1:1 the same way, each clipped to its own page box.
    /// Neither is scaled; the page content is redrawn as vector content, not
    /// rasterized. The overlay must have the output's page size. The original
    /// file is only read; `output` may not be the original or the overlay,
    /// and when it exists it must be a regular file, never a directory or a
    /// symbolic link. On error nothing is written to `output`.
    public static func stamp(original: URL, overlay: URL, pageMode: PageMode = .a4, output: URL) throws {
        let inputs = [(original, "blank form"), (overlay, "compiled overlay")]
        try refuseOverwriting(inputs: inputs, with: output)
        let page = try singlePage(original, isOriginal: true)
        let box = page.getBoxRect(.cropBox)
        let target = try targetSize(of: page, pageMode: pageMode)

        let overlayPage = try singlePage(overlay, isOriginal: false)
        let overlayRotation = ((Int(overlayPage.rotationAngle) % 360) + 360) % 360
        guard overlayRotation == 0 else { throw FormFillError.rotatedOverlay(degrees: overlayRotation) }
        let overlayBox = overlayPage.getBoxRect(.cropBox)
        guard abs(overlayBox.width - target.width) <= PageGeometry.exactTolerance,
              abs(overlayBox.height - target.height) <= PageGeometry.exactTolerance else {
            throw FormFillError.overlayWrongSize(width: Double(overlayBox.width), height: Double(overlayBox.height),
                                                 expectedWidth: Double(target.width), expectedHeight: Double(target.height))
        }

        // A short name, so a long output name still fits the file system.
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".pff-\(UUID().uuidString.prefix(8)).tmp")
        var mediaBox = CGRect(origin: .zero, size: target)
        guard let context = CGContext(temporary as CFURL, mediaBox: &mediaBox, nil) else {
            throw FormFillError.outputWriteFailed(output.path)
        }
        context.beginPDFPage(nil)
        for (source, sourceBox) in [(page, box), (overlayPage, overlayBox)] {
            context.saveGState()
            // Map the source's top-left corner onto the target's top-left corner.
            context.translateBy(x: -sourceBox.minX, y: target.height - sourceBox.maxY)
            // drawPDFPage does not clip to the page's box; a viewer would.
            context.clip(to: sourceBox)
            context.drawPDFPage(source)
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()

        do {
            // Checked again: the output may have appeared since the first check.
            try refuseOverwriting(inputs: inputs, with: output)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        try moveIntoPlace(temporary, to: output)
    }

    /// rename(2): one atomic step that replaces a regular file (or a link
    /// entry, without following it) and fails on a directory, deleting
    /// nothing. On failure the temporary file is removed.
    static func moveIntoPlace(_ temporary: URL, to output: URL) throws {
        guard rename(temporary.path, output.path) != 0 else { return }
        let code = errno
        try? FileManager.default.removeItem(at: temporary)
        if code == EISDIR || code == ENOTEMPTY || code == EEXIST || code == ENOTDIR {
            throw FormFillError.outputNotAFile(path: output.path)
        }
        throw FormFillError.outputWriteFailed(output.path)
    }

    /// The output page size for `original` in `pageMode`, after the checks
    /// that do not need the overlay: one unrotated page without annotations,
    /// and for A4 a near-A4 page with no ink in the strip A4 would remove.
    public static func targetSize(original: URL, pageMode: PageMode) throws -> CGSize {
        try targetSize(of: singlePage(original, isOriginal: true), pageMode: pageMode)
    }

    static func targetSize(of page: CGPDFPage, pageMode: PageMode) throws -> CGSize {
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        guard rotation == 0 else { throw FormFillError.rotatedOriginal(degrees: rotation) }
        let annotations = annotationCount(page)
        guard annotations == 0 else { throw FormFillError.annotatedOriginal(count: annotations) }
        let box = page.getBoxRect(.cropBox)
        switch pageMode {
        case .original:
            return box.size
        case .a4:
            guard PageGeometry.classify(box.size) != .other else {
                throw FormFillError.notNearA4(width: Double(box.width), height: Double(box.height))
            }
            let ink = try PageGeometry.inkInRemovedStrip(page: page, target: PageGeometry.a4, dpi: stripCheckDPI)
            guard ink == 0 else { throw FormFillError.inkInRemovedStrip(pixels: ink) }
            return PageGeometry.a4
        }
    }

    /// Entries of the page's /Annots array: links, form-field widgets,
    /// comments. Their appearances are not part of the page content, so a
    /// redraw drops them and a render of the original does not show them.
    static func annotationCount(_ page: CGPDFPage) -> Int {
        guard let dictionary = page.dictionary else { return 0 }
        var annotations: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Annots", &annotations), let annotations else { return 0 }
        return CGPDFArrayGetCount(annotations)
    }

    /// Throws when `output` is, or links to, one of `inputs`, or when it
    /// exists and is not a regular file: replacing a directory would delete
    /// everything in it, and writing a symbolic link would write elsewhere.
    static func refuseOverwriting(inputs: [(URL, String)], with output: URL) throws {
        for (input, role) in inputs where sameFile(output, input) {
            throw FormFillError.outputIsInput(path: output.path, role: role)
        }
        if let type = itemType(output), type != .typeRegular {
            throw FormFillError.outputNotAFile(path: output.path)
        }
    }

    /// The type of the item at `url` without following a final symbolic
    /// link, or nil when nothing is there.
    static func itemType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    /// The name of the first of `protected` that `candidate` would replace,
    /// by path (also for files that do not exist yet) or by file identity.
    static func collision(of candidate: URL, with protected: [(URL, String)]) -> String? {
        let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return protected.first { url, _ in
            url.resolvingSymlinksInPath().standardizedFileURL.path == path || sameFile(candidate, url)
        }?.1
    }

    /// True when both paths name one existing file: after resolving symbolic
    /// links, or by file identity (hard links, case-insensitive volumes).
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let ra = a.resolvingSymlinksInPath().standardizedFileURL, rb = b.resolvingSymlinksInPath().standardizedFileURL
        if ra.path == rb.path { return true }
        let fm = FileManager.default
        guard fm.fileExists(atPath: ra.path), fm.fileExists(atPath: rb.path),
              let ia = try? ra.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let ib = try? rb.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return ia.isEqual(ib)
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
