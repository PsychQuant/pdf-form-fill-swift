import CoreGraphics
import CoreText
import Foundation
@testable import PDFFormFill
import PDFVisualDiff
import Testing

/// Fixes from the fifth verification round of PsychQuant/macdoc#240.
struct Round5FixTests {

    /// A one-page A4 PDF written by hand, so the content stream can use
    /// operators CoreGraphics never emits. `xobject` adds a form XObject /X0
    /// with its own content stream and, when `selfReferencing`, a resource
    /// entry pointing back at itself.
    /// /F1 has a width of 500 (6 bp at 12 bp) for every printable ASCII
    /// code; /F2 has no width data. `annotated` adds a link annotation.
    static func handMadePDF(content: String, xobject: String? = nil, selfReferencing: Bool = false,
                            bbox: String = "-100000 -100000 100000 100000", annotated: Bool = false) throws -> URL {
        var objects: [String] = []
        let widths = Array(repeating: "500", count: 95).joined(separator: " ")
        let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32 /LastChar 126 /Widths [\(widths)] >>"
        let xobjectResource = xobject == nil ? "" : " /XObject << /X0 5 0 R >>"
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        let annots = annotated ? " /Annots [<< /Type /Annot /Subtype /Link /Rect [10 10 50 50] >>]" : ""
        objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R "
                       + "/Resources << /Font << /F1 6 0 R /F2 7 0 R >>\(xobjectResource) >>\(annots) >>")
        objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        if let xobject {
            let inner = selfReferencing ? "/Resources << /XObject << /X0 5 0 R >> /Font << /F1 6 0 R >> >>" : "/Resources << /Font << /F1 6 0 R >> >>"
            objects.append("<< /Type /XObject /Subtype /Form /BBox [\(bbox)] \(inner) /Length \(xobject.utf8.count) >>\nstream\n\(xobject)\nendstream")
        } else {
            objects.append("<< >>")
        }
        objects.append(font)
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hand-\(UUID().uuidString).pdf")
        try Data(pdf.utf8).write(to: url)
        return url
    }

    static func scan(_ url: URL) throws -> ContentExtent.Result {
        ContentExtent.scan(page: try PageRaster.page(url: url, index: 0))
    }

    static func positionsOutside(_ url: URL) throws -> Int {
        try scan(url).outside
    }

    @Test("a TJ displacement that pushes text off the page is followed")
    func tjDisplacement() throws {
        let url = try Self.handMadePDF(content: "BT /F1 12 Tf 1 0 0 1 100 400 Tm [-200000 (X)] TJ ET")
        #expect(try Self.positionsOutside(url) > 0)
    }

    @Test("text that starts two page widths to the right is found")
    func originJustPastEdge() throws {
        let url = try Self.handMadePDF(content: "BT /F1 12 Tf 1 0 0 1 1190 400 Tm (123) Tj ET")
        #expect(try Self.positionsOutside(url) > 0)
    }

    @Test("text and painted paths on the page are not reported")
    func onPage() throws {
        let url = try Self.handMadePDF(content: "BT /F1 12 Tf 1 0 0 1 100 400 Tm [(A) -500 (B)] TJ ET 100 100 m 300 100 l S")
        #expect(try Self.positionsOutside(url) == 0)
    }

    @Test("a clipping path that is never painted is not reported")
    func unpaintedClip() throws {
        let url = try Self.handMadePDF(content: "q -5000 -5000 20000 20000 re W n BT /F1 12 Tf 1 0 0 1 100 400 Tm (A) Tj ET Q")
        #expect(try Self.positionsOutside(url) == 0)
    }

    @Test("a form XObject that draws itself is stopped quickly and counted as undecidable")
    func selfReferencingForm() throws {
        let url = try Self.handMadePDF(content: "/X0 Do", xobject: "/X0 Do /X0 Do BT /F1 12 Tf 1 0 0 1 100 400 Tm (A) Tj ET",
                                       selfReferencing: true)
        let start = Date()
        let result = try Self.scan(url)
        #expect(result.undecidable > 0)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("form XObject content is scanned with its matrix")
    func formContent() throws {
        let url = try Self.handMadePDF(content: "q 1 0 0 1 5000 0 cm /X0 Do Q", xobject: "BT /F1 12 Tf 1 0 0 1 100 400 Tm (A) Tj ET")
        #expect(try Self.positionsOutside(url) > 0)
    }

    @Test("a field at the seam two page widths to the right is refused", .enabled(if: xelatexAvailable, "xelatex not found"))
    func seam() throws {
        let tex = try FormFillerTests.project(typed: "\\at{1190}{100}{12}{123};")
        let error = #expect(throws: FormFillError.self) {
            try FormFiller.fill(tex: tex, output: tex.deletingLastPathComponent().appendingPathComponent("out.pdf"))
        }
        guard case .overlayTextOffPage? = error else {
            Issue.record("expected overlayTextOffPage, got \(String(describing: error))")
            return
        }
    }

    @Test("a label with ^^ notation stays inside its comment", .enabled(if: xelatexAvailable, "xelatex not found"))
    func caretNotationInLabel() throws {
        let dir = try OverlayCompilerTests.workspace()
        let blank = dir.appendingPathComponent("blank.pdf")
        try SyntheticPDF.write([SyntheticPDF.Page(size: SyntheticPDF.a4, items: [
            .text("^^0a\\undefinedcommandxyz", at: CGPoint(x: 100, y: 100), size: 10, font: "Helvetica"),
        ])], to: blank)
        let tex = dir.appendingPathComponent("filled.tex")
        try FormSkeleton.generate(blankForm: blank, reference: "blank.pdf").write(to: tex, atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: tex, encoding: .utf8).contains("^^0a"))
        let pdf = try OverlayCompiler().compile(tex: tex)
        OverlayCompiler.discard(pdf)
    }
}
