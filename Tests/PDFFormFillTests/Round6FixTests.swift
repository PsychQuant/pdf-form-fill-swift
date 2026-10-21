import CoreGraphics
import Foundation
@testable import PDFFormFill
import PDFVisualDiff
import Testing

/// Fixes from the sixth verification round of PsychQuant/macdoc#240: the pen
/// follows glyph widths and the full text state, clips are honoured, form
/// reuse is not mistaken for nesting, and annotated overlays are refused.
struct Round6FixTests {

    static func scan(_ content: String, xobject: String? = nil, bbox: String = "-100000 -100000 100000 100000")
        throws -> ContentExtent.Result {
        try Round5FixTests.scan(Round5FixTests.handMadePDF(content: content, xobject: xobject, bbox: bbox))
    }

    @Test("kerning that moves the pen left does not push on-page text off the page")
    func kerningNearLeftEdge() throws {
        let result = try Self.scan("BT /F1 12 Tf 1 0 0 1 20 400 Tm [(AAAA) 500 (B) 500 (C) 500 (D) 500 (E)] TJ ET")
        #expect(result == ContentExtent.Result())
    }

    @Test("glyph widths carry later glyphs off the page")
    func advanceCarriesTextOff() throws {
        let run = String(repeating: "A", count: 300)
        #expect(try Self.scan("BT /F1 12 Tf 1 0 0 1 100 400 Tm (\(run)X) Tj ET").outside > 0)
    }

    @Test("invisible glyphs advance the pen but are not marked")
    func invisibleText() throws {
        let run = String(repeating: "A", count: 300)
        #expect(try Self.scan("BT /F1 12 Tf 3 Tr 1 0 0 1 100 400 Tm (\(run)) Tj 0 Tr (X) Tj ET").outside > 0)
        #expect(try Self.scan("BT /F1 12 Tf 3 Tr 1 0 0 1 5000 400 Tm (A) Tj ET").outside == 0)
    }

    @Test("Q restores the font size used by later TJ displacements")
    func textStateRestoredByQ() throws {
        let content = "BT /F1 12 Tf ET q BT /F1 1 Tf ET Q BT 1 0 0 1 100 400 Tm [-100000 (X)] TJ ET"
        #expect(try Self.scan(content).outside > 0)
    }

    @Test("a form XObject does not change the text state outside it")
    func formIsolatesTextState() throws {
        let content = "BT /F1 12 Tf ET /X0 Do BT 1 0 0 1 100 400 Tm [-100000 (X)] TJ ET"
        #expect(try Self.scan(content, xobject: "BT /F1 1 Tf ET").outside > 0)
    }

    @Test("text rise, character spacing and word spacing move the glyphs", arguments: [
        "BT /F1 12 Tf 5000 Ts 1 0 0 1 100 400 Tm (A) Tj ET",
        "BT /F1 12 Tf 3000 Tc 1 0 0 1 100 400 Tm (AB) Tj ET",
        "BT /F1 12 Tf 3000 Tw 1 0 0 1 100 400 Tm (A B) Tj ET",
    ])
    func textStateMovesGlyphs(content: String) throws {
        #expect(try Self.scan(content).outside > 0)
    }

    @Test("an origin just off the edge is left to the pixel check")
    func originJustOffEdge() throws {
        #expect(try Self.scan("BT /F1 12 Tf 1 0 0 1 -3 400 Tm (A) Tj ET") == ContentExtent.Result())
    }

    @Test("drawing under a clip on the page is not reported")
    func clippedDrawing() throws {
        #expect(try Self.scan("q 400 40 120 100 re W n 0 0 m 5000 5000 l S Q").outside == 0)
        #expect(try Self.scan("0 0 m 5000 5000 l S").outside > 0)
        #expect(try Self.scan("0 0 m 100 100 l S", xobject: nil).outside == 0)
    }

    @Test("a form's bounding box clips its content")
    func formBBoxClips() throws {
        #expect(try Self.scan("/X0 Do", xobject: "0 0 m 5000 5000 l S", bbox: "0 0 100 100").outside == 0)
        #expect(try Self.scan("/X0 Do", xobject: "0 0 m 5000 5000 l S").outside > 0)
    }

    @Test("reusing one form many times is neither nesting nor off the page")
    func manyInvocations() throws {
        let content = String(repeating: "/X0 Do ", count: 2500)
        #expect(try Self.scan(content, xobject: "100 100 m 110 110 l S") == ContentExtent.Result())
    }

    @Test("text in a font without width data cannot be placed")
    func fontWithoutWidths() throws {
        let result = try Self.scan("BT /F2 12 Tf 1 0 0 1 100 400 Tm (A) Tj ET")
        #expect(result.undecidable > 0)
        #expect(result.outside == 0)
    }

    @Test("an overlay with annotations is refused before stamping")
    func annotatedOverlay() throws {
        let dir = try OverlayCompilerTests.workspace()
        let original = dir.appendingPathComponent("blank.pdf")
        try SyntheticPDF.write([SyntheticPDF.Page(size: SyntheticPDF.a4, items: FormStamperTests.formItems)], to: original)
        let overlay = try Round5FixTests.handMadePDF(content: "BT /F1 12 Tf 1 0 0 1 100 400 Tm (A) Tj ET", annotated: true)
        let output = dir.appendingPathComponent("out.pdf")
        #expect(throws: FormFillError.annotatedOverlay(count: 1)) {
            try FormStamper.stamp(original: original, overlay: overlay, output: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    /// A PDF from raw object bodies (object 1 is the catalog), with an xref.
    static func rawPDF(_ objects: [String]) throws -> URL {
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
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID().uuidString).pdf")
        try Data(pdf.utf8).write(to: url)
        return url
    }

    static func stream(_ dictionary: String, _ content: String) -> String {
        "<< \(dictionary) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
    }

    @Test("a form without resources uses its caller's, as a renderer does")
    func formInheritsResources() throws {
        let url = try Self.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R "
                + "/Resources << /XObject << /X0 5 0 R /X1 6 0 R >> >> >>",
            Self.stream("", "/X0 Do"),
            Self.stream("/Type /XObject /Subtype /Form /BBox [-100000 -100000 100000 100000]", "/X1 Do"),
            Self.stream("/Type /XObject /Subtype /Form /BBox [-100000 -100000 100000 100000]", "5000 400 m 5050 400 l S"),
        ])
        #expect(try Round5FixTests.scan(url).outside > 0)
    }

    @Test("an XObject name that cannot be resolved cannot be placed")
    func unresolvedXObject() throws {
        #expect(try Self.scan("/Nope Do").undecidable > 0)
    }

    @Test("horizontal scaling widens TJ displacements")
    func horizontalScale() throws {
        #expect(try Self.scan("BT /F1 12 Tf 1000 Tz 1 0 0 1 100 400 Tm [-10000 (X)] TJ ET").outside > 0)
        #expect(try Self.scan("BT /F1 12 Tf 1 0 0 1 100 400 Tm [-10000 (X)] TJ ET").outside == 0)
    }

    @Test("a positive TJ number moves the pen left")
    func positiveDisplacementMovesLeft() throws {
        #expect(try Self.scan("BT /F1 12 Tf 1 0 0 1 100 400 Tm [100000 (X)] TJ ET").outside > 0)
    }

    @Test("an inline image is placed by its corners")
    func inlineImage() throws {
        #expect(try Self.scan("q 10 0 0 10 3000 400 cm BI /W 1 /H 1 /BPC 8 /CS /G ID A EI Q").outside > 0)
        #expect(try Self.scan("q 10 0 0 10 300 400 cm BI /W 1 /H 1 /BPC 8 /CS /G ID A EI Q").outside == 0)
    }

    /// A project with the skeleton's CJK setup, typed at the given fields.
    static func cjkProject(typed: String) throws -> URL {
        let dir = try OverlayCompilerTests.workspace()
        try SyntheticPDF.write([SyntheticPDF.Page(size: SyntheticPDF.a4, items: [])],
                               to: dir.appendingPathComponent("blank.pdf"))
        return try OverlayCompilerTests.write("""
        \\documentclass{article}
        \\usepackage[a4paper,margin=0pt]{geometry}
        \\usepackage{tikz}
        \\usetikzlibrary{calc}
        \\usepackage{xeCJK}
        \\setCJKmainfont{PingFang TC}
        \\pagestyle{empty}
        \\newcommand{\\BlankForm}{blank.pdf}
        \\newcommand{\\at}[3]{\\node[anchor=base west,inner sep=0pt,font=\\fontsize{#3}{#3}\\selectfont] at ($(current page.north west)+(#1 bp,-#2 bp)$)}
        \\begin{document}
        \\null
        \\begin{tikzpicture}[remember picture,overlay]
        \(typed)
        \\end{tikzpicture}
        \\end{document}
        """, in: dir, name: "filled.tex")
    }

    @Test("full-width punctuation and kerned Latin text near the left margin are filled", .enabled(if: xelatexAvailable, "xelatex not found"),
          arguments: ["\\at{40}{100}{12}{（一）「甲」、「乙」：丙，丁。「戊」、「己」。};",
                      "\\at{6}{140}{12}{AVAVAV TAVAWAY};",
                      "\\at{2}{180}{10}{「臺北市」};"])
    func legitimateTextNearMargin(typed: String) throws {
        let tex = try Self.cjkProject(typed: typed)
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let result = try FormFiller.fill(tex: tex, output: output)
        #expect(result.passed, "\(result)")
    }

    @Test("ideographic spaces that carry a glyph off the page are refused", .enabled(if: xelatexAvailable, "xelatex not found"))
    func ideographicSpacesCarryGlyphOff() throws {
        let spaces = String(repeating: "\u{3000}", count: 110)
        let tex = try Self.cjkProject(typed: "\\at{100}{100}{12}{\(spaces)字};")
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        #expect(throws: FormFillError.self) {
            try FormFiller.fill(tex: tex, output: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
