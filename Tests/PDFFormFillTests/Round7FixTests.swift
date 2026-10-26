import CoreGraphics
import Foundation
@testable import PDFFormFill
import PDFVisualDiff
import Testing

/// Fixes from the seventh verification round of PsychQuant/macdoc#240.
struct Round7FixTests {

    /// A page whose resources hold /F1 (width 500 for printable ASCII) and an
    /// ExtGState /GS1 that sets /F1 at 100 bp.
    static func pageWithExtGState(_ content: String) throws -> ContentExtent.Result {
        let widths = Array(repeating: "500", count: 95).joined(separator: " ")
        let url = try Round6FixTests.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R "
                + "/Resources << /Font << /F1 5 0 R >> /ExtGState << /GS1 << /Font [5 0 R 100] >> >> >> >>",
            Round6FixTests.stream("", content),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32 /LastChar 126 /Widths [\(widths)] >>",
        ])
        return try Round5FixTests.scan(url)
    }

    @Test("a narrow glyph at a large size on the page is not reported")
    func largeGlyphOnPage() throws {
        #expect(try Round6FixTests.scan("BT /F1 400 Tf 1 0 0 1 100 400 Tm (.) Tj ET") == ContentExtent.Result())
    }

    @Test("an ExtGState font size is used for later TJ displacements")
    func extGStateFont() throws {
        #expect(try Self.pageWithExtGState("BT /F1 12 Tf /GS1 gs 1 0 0 1 100 400 Tm [-20000 (X)] TJ ET").outside > 0)
        #expect(try Self.pageWithExtGState("BT /F1 12 Tf 1 0 0 1 100 400 Tm [-20000 (X)] TJ ET").outside == 0)
    }

    @Test("an ExtGState name that cannot be resolved cannot be placed")
    func unresolvedExtGState() throws {
        #expect(try Self.pageWithExtGState("/Nope gs BT /F1 12 Tf 1 0 0 1 100 400 Tm (A) Tj ET").undecidable > 0)
    }

    @Test("an operator whose operands cannot be read is unverifiable", arguments: [
        "BT /F1 12 Tf 1 0 0 1 100 400 Tm 5 Tj ET",
        "BT /F1 12 Tf 1 0 0 1 100 400 Tm (A) TJ ET",
        "/F1 cm",
    ])
    func unreadableOperands(content: String) throws {
        #expect(try Round6FixTests.scan(content).undecidable > 0)
    }

    @Test("a full stop set at 400 bp near the left margin is filled", .enabled(if: xelatexAvailable, "xelatex not found"))
    func largePointSizeFill() throws {
        let tex = try Round6FixTests.cjkProject(typed: "\\at{100}{500}{400}{.};")
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let result = try FormFiller.fill(tex: tex, output: output)
        #expect(result.passed, "\(result)")
    }
}
