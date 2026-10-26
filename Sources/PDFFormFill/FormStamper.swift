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

    /// Writes a new single-page PDF to `output`: the original page's content
    /// streams and resources copied byte for byte, then the overlay page as
    /// a form XObject whose top-left corner lands on the page's. Nothing is
    /// redrawn, scaled or rasterized: in page mode `a4` only the page box
    /// changes, keeping the original's top-left corner, so the original
    /// renders with exactly the transform it had. The overlay must have the
    /// output's page size. The original
    /// file is only read; `output` may not be the original or the overlay,
    /// and when it exists it must be a regular file, never a directory or a
    /// symbolic link. On error nothing is written to `output`.
    public static func stamp(original: URL, overlay: URL, pageMode: PageMode = .a4, output: URL) throws {
        let inputs = [(original, "blank form"), (overlay, "compiled overlay")]
        try refuseOverwriting(inputs: inputs, with: output)
        let (originalDocument, page) = try singleDocument(original, isOriginal: true)
        let box = page.getBoxRect(.cropBox)
        let target = try targetSize(of: page, pageMode: pageMode)

        let (overlayDocument, overlayPage) = try singleDocument(overlay, isOriginal: false)
        let overlayRotation = ((Int(overlayPage.rotationAngle) % 360) + 360) % 360
        guard overlayRotation == 0 else { throw FormFillError.rotatedOverlay(degrees: overlayRotation) }
        // Stamping copies only page content, so annotations would be lost unseen.
        let overlayAnnotations = annotationCount(overlayPage)
        guard overlayAnnotations == 0 else { throw FormFillError.annotatedOverlay(count: overlayAnnotations) }
        let overlayBox = overlayPage.getBoxRect(.cropBox)
        guard abs(overlayBox.width - target.width) <= PageGeometry.exactTolerance,
              abs(overlayBox.height - target.height) <= PageGeometry.exactTolerance else {
            throw FormFillError.overlayWrongSize(width: Double(overlayBox.width), height: Double(overlayBox.height),
                                                 expectedWidth: Double(target.width), expectedHeight: Double(target.height))
        }

        // A name independent of the output's, so a long output name still
        // fits the file system, with 128 random bits.
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(".pff-\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).tmp")
        // The page keeps the original's top-left corner, so the original's
        // content renders with exactly the transform it had on its own.
        let pageBox = pageMode == .a4
            ? CGRect(x: box.minX, y: box.maxY - target.height, width: target.width, height: target.height)
            : box
        let data: Data
        do {
            data = try compose(original: page, originalCatalog: originalDocument.catalog, overlay: overlayPage,
                               overlayCatalog: overlayDocument.catalog, overlayBox: overlayBox, pageBox: pageBox)
        } catch let error as PDFObjectWriter.Unsupported {
            throw FormFillError.unstampable(error.reason)
        }
        do {
            try data.write(to: temporary, options: .withoutOverwriting)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw FormFillError.outputWriteFailed(output.path)
        }

        do {
            // Checked again: the output may have appeared since the first check.
            try refuseOverwriting(inputs: inputs, with: output)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        // rename(2) replaces the file, so carry over the old one's permissions.
        if itemType(output) == .typeRegular,
           let mode = (try? FileManager.default.attributesOfItem(atPath: output.path))?[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temporary.path)
        }
        try moveIntoPlace(temporary, to: output)
    }
    /// The output PDF: one page whose contents are the original's streams,
    /// unchanged and kept apart by q/Q, followed by the overlay drawn as a
    /// form XObject under a name the original does not use.
    static func compose(original page: CGPDFPage, originalCatalog: CGPDFDictionaryRef?, overlay: CGPDFPage,
                        overlayCatalog: CGPDFDictionaryRef?, overlayBox: CGRect, pageBox: CGRect) throws -> Data {
        typealias W = PDFObjectWriter
        var writer = PDFObjectWriter()
        let catalog = writer.reserve(), pages = writer.reserve(), pageNumber = writer.reserve()

        // The overlay's own layer settings cannot be merged into the original's.
        var layers: CGPDFObjectRef?
        if let overlayCatalog, CGPDFDictionaryGetObject(overlayCatalog, "OCProperties", &layers) {
            throw W.Unsupported(reason: "the overlay uses optional content (layers)")
        }
        var overlayContent = Data()
        for stream in try contentStreams(of: overlay) {
            var format = CGPDFDataFormat.raw
            guard let data = CGPDFStreamCopyData(stream, &format), format == .raw else {
                throw W.Unsupported(reason: "undecodable overlay content")
            }
            overlayContent.append(data as Data)
            overlayContent.append(Data("\n".utf8))
        }
        let tx = try W.number(pageBox.minX - overlayBox.minX), ty = try W.number(pageBox.maxY - overlayBox.maxY)
        var formEntries: [(String, Data)] = [
            ("Type", Data("/XObject".utf8)), ("Subtype", Data("/Form".utf8)),
            ("BBox", try rectangle(overlayBox)), ("Matrix", Data("[1 0 0 1 \(tx) \(ty)]".utf8)),
            ("Filter", Data("/FlateDecode".utf8)),
        ]
        if let resources = ContentExtent.inheritedResources(of: overlay) {
            formEntries.append(("Resources", W.reference(try writer.dictionary(resources))))
        }
        if let group = try groupEntry(of: overlay, writer: &writer) { formEntries.append(("Group", group)) }
        let form = writer.stream(entries: formEntries, data: try W.deflate(overlayContent))

        var resources: [(String, Data)] = []
        var xobjects: [(String, Data)] = []
        if let original = ContentExtent.inheritedResources(of: page) {
            resources = try writer.entries(of: original, skipping: ["XObject"])
            var existing: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(original, "XObject", &existing), let existing {
                xobjects = try writer.entries(of: existing)
            }
        }
        var name = "PFFOverlay"
        var suffix = 0
        while xobjects.contains(where: { $0.0 == W.nameKey(Array(name.utf8)) }) {
            suffix += 1
            name = "PFFOverlay\(suffix)"
        }
        xobjects.append((name, W.reference(form)))
        resources.append(("XObject", W.dictionaryBody(xobjects)))

        // The original is clipped to its own crop box, as a render of it is;
        // when the crop box holds the whole output page the page box does
        // that already, and a second clip at the same edge would be redundant.
        let crop = page.getBoxRect(.cropBox)
        var prefix = "q\n"
        if !crop.contains(pageBox) {
            let clip = try [crop.minX, crop.minY, crop.width, crop.height].map(W.number).joined(separator: " ")
            prefix = "q \(clip) re W n\n"
        }
        var contents = [writer.stream(entries: [], data: Data(prefix.utf8))]
        for stream in try contentStreams(of: page) { contents.append(try writer.stream(stream)) }
        // Close every q the original left open, then the wrapper's own, so
        // the overlay is drawn in the page's untouched graphics state.
        let open = openSaveLevels(of: page)
        let restore = String(repeating: "Q\n", count: open + 1)
        contents.append(writer.stream(entries: [], data: Data("\n\(restore)q \(W.name(name)) Do Q\n".utf8)))

        var pageEntries: [(String, Data)] = [
            ("Type", Data("/Page".utf8)), ("Parent", W.reference(pages)),
            ("MediaBox", try rectangle(pageBox)), ("CropBox", try rectangle(pageBox)),
            ("Resources", W.dictionaryBody(resources)),
            ("Contents", Data(("[" + contents.map { "\($0) 0 R" }.joined(separator: " ") + "]").utf8)),
        ]
        if let group = try groupEntry(of: page, writer: &writer) { pageEntries.append(("Group", group)) }
        writer.set(pageNumber, W.dictionaryBody(pageEntries))
        writer.set(pages, Data("<< /Type /Pages /Kids [\(pageNumber) 0 R] /Count 1 >>".utf8))
        // Which optional-content layers are shown is set in the catalog;
        // without it, layers the original hides would be drawn.
        var catalogEntries: [(String, Data)] = [("Type", Data("/Catalog".utf8)), ("Pages", W.reference(pages))]
        if let properties = try optionalContent(of: originalCatalog, writer: &writer) {
            catalogEntries.append(("OCProperties", properties))
        }
        writer.set(catalog, W.dictionaryBody(catalogEntries))
        return try writer.data(root: catalog)
    }

    /// How many q the page's content leaves open at its end (extra Q
    /// clamped at zero, as renderers ignore them).
    static func openSaveLevels(of page: CGPDFPage) -> Int {
        final class Depth { var value = 0 }
        let depth = Depth()
        guard let table = CGPDFOperatorTableCreate() else { return 0 }
        defer { CGPDFOperatorTableRelease(table) }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            info.map { Unmanaged<Depth>.fromOpaque($0).takeUnretainedValue() }?.value += 1
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let d = info.map({ Unmanaged<Depth>.fromOpaque($0).takeUnretainedValue() }) else { return }
            d.value = max(0, d.value - 1)
        }
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(depth).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        return depth.value
    }

    /// The page's /Contents: one stream or an array of streams.
    static func contentStreams(of page: CGPDFPage) throws -> [CGPDFStreamRef] {
        guard let dictionary = page.dictionary else { return [] }
        var stream: CGPDFStreamRef?
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetStream(dictionary, "Contents", &stream), let stream { return [stream] }
        guard CGPDFDictionaryGetArray(dictionary, "Contents", &array), let array else { return [] }
        return try (0..<CGPDFArrayGetCount(array)).map { index in
            var entry: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, index, &entry), let entry else {
                throw PDFObjectWriter.Unsupported(reason: "a page content entry is not a stream")
            }
            return entry
        }
    }

    /// The document's /OCProperties, copied so that the same layer objects
    /// the page's content refers to keep their visibility.
    static func optionalContent(of catalog: CGPDFDictionaryRef?, writer: inout PDFObjectWriter) throws -> Data? {
        var properties: CGPDFObjectRef?
        guard let catalog, CGPDFDictionaryGetObject(catalog, "OCProperties", &properties), let properties else { return nil }
        return try writer.value(properties)
    }

    /// The page's transparency /Group, which changes how its content blends.
    static func groupEntry(of page: CGPDFPage, writer: inout PDFObjectWriter) throws -> Data? {
        var group: CGPDFObjectRef?
        guard let dictionary = page.dictionary, CGPDFDictionaryGetObject(dictionary, "Group", &group), let group else {
            return nil
        }
        return try writer.value(group)
    }

    static func rectangle(_ rect: CGRect) throws -> Data {
        let values = try [rect.minX, rect.minY, rect.maxX, rect.maxY].map(PDFObjectWriter.number)
        return Data(("[" + values.joined(separator: " ") + "]").utf8)
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
    /// comments. Their appearances are not part of the page content, so
    /// stamping does not copy them and a render of the original does not show them.
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
        try singleDocument(url, isOriginal: isOriginal).page
    }

    /// The document and its one page; a CGPDFPage does not keep its document
    /// alive, so callers that need the catalog hold on to the document.
    private static func singleDocument(_ url: URL, isOriginal: Bool) throws -> (document: CGPDFDocument, page: CGPDFPage) {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw FormFillError.unreadablePDF(url.path)
        }
        // A document with a user password opens locked; try the empty one.
        if document.isEncrypted, !document.isUnlocked, !document.unlockWithPassword("") {
            throw FormFillError.lockedPDF(url.path)
        }
        guard document.numberOfPages > 0 else { throw FormFillError.emptyPDF(url.path) }
        guard document.numberOfPages == 1, let page = document.page(at: 1) else {
            throw isOriginal ? FormFillError.multiPageOriginal(pages: document.numberOfPages)
                             : FormFillError.overlayPageCount(document.numberOfPages)
        }
        return (document, page)
    }
}
