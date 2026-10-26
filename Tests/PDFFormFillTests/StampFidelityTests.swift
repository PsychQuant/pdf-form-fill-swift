import CoreGraphics
import Foundation
@testable import PDFFormFill
import PDFVisualDiff
import Testing

/// Stamping copies the original's content instead of redrawing it, so forms
/// whose lines sit at fractional positions, curves and circled options pass
/// the threshold-free checks (verification round 8 of PsychQuant/macdoc#240).
struct StampFidelityTests {

    /// A table form drawn by a CoreGraphics PDF context with 0.5 bp lines at
    /// fractional positions.
    static func tableForm(size: CGSize) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("table-\(UUID().uuidString).pdf")
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        var media = CGRect(origin: .zero, size: size)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(0.5)
        for i in 0..<60 {
            let y = 60.37 + Double(i) * 12.13
            context.move(to: CGPoint(x: 40.2, y: y))
            context.addLine(to: CGPoint(x: 555.7, y: y))
        }
        for i in 0..<8 {
            let x = 40.2 + Double(i) * 73.57
            context.move(to: CGPoint(x: x, y: 60.37))
            context.addLine(to: CGPoint(x: x, y: 60.37 + 59 * 12.13))
        }
        context.strokePath()
        context.endPDFPage()
        context.closePDF()
        return url
    }

    /// A fill project whose blank form is a copy of `blank`, typed with `typed`
    /// (TikZ lines inside the overlay picture).
    static func project(blank: URL, typed: String) throws -> URL {
        let dir = try OverlayCompilerTests.workspace()
        try FileManager.default.copyItem(at: blank, to: dir.appendingPathComponent("blank.pdf"))
        let tex = try Round6FixTests.cjkProject(typed: typed)
        let moved = dir.appendingPathComponent("filled.tex")
        try FileManager.default.copyItem(at: tex, to: moved)
        return moved
    }

    @Test("a table with fractional-position lines passes in both page modes",
          .enabled(if: xelatexAvailable, "xelatex not found"),
          arguments: [(CGSize(width: 595.2756, height: 841.8898), PageMode.a4),
                      (CGSize(width: 595.2756, height: 841.8898), PageMode.original),
                      (CGSize(width: 595.32, height: 841.92), PageMode.a4)])
    func fractionalTable(size: CGSize, mode: PageMode) throws {
        let blank = try Self.tableForm(size: size)
        defer { try? FileManager.default.removeItem(at: blank) }
        let tex = try Self.project(blank: blank, typed: "\\at{20}{30}{12}{甲};")
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let result = try FormFiller.fill(tex: tex, output: output, pageMode: mode)
        #expect(result.passed, "\(result.report.checks.filter { $0.count > 0 })")
    }

    @Test("a form made with xelatex (rounded box, circles, a curve) passes in both page modes",
          .enabled(if: xelatexAvailable, "xelatex not found"), arguments: [PageMode.a4, PageMode.original])
    func curvedForm(mode: PageMode) throws {
        let dir = try OverlayCompilerTests.workspace()
        let source = try OverlayCompilerTests.write("""
        \\documentclass{article}
        \\usepackage[a4paper,margin=0pt]{geometry}
        \\usepackage{tikz}
        \\pagestyle{empty}
        \\begin{document}
        \\null
        \\begin{tikzpicture}[remember picture,overlay]
        \\draw[rounded corners=6bp,line width=0.6bp] ([xshift=60bp,yshift=-300bp]current page.north west)
          rectangle ++(400bp,-200bp);
        \\foreach \\i in {0,...,9} { \\draw[line width=0.5bp] ([xshift={80bp+\\i*37.3bp},yshift=-420.7bp]current page.north west)
          circle (7.3bp); }
        \\draw[line width=0.7bp] ([xshift=70bp,yshift=-560bp]current page.north west) .. controls +(120bp,80bp)
          and +(-90bp,-60bp) .. ++(380bp,10bp);
        \\end{tikzpicture}
        \\end{document}
        """, in: dir, name: "form.tex")
        let compiled = try OverlayCompiler().compile(tex: source)
        let blank = dir.appendingPathComponent("curved.pdf")
        try FileManager.default.copyItem(at: compiled, to: blank)
        OverlayCompiler.discard(compiled)
        let tex = try Self.project(blank: blank, typed: "\\at{80}{120}{12}{乙};")
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let result = try FormFiller.fill(tex: tex, output: output, pageMode: mode)
        #expect(result.passed, "\(result.report.checks.filter { $0.count > 0 })")
    }

    @Test("circled options, dots and a shading in the overlay reach the output exactly",
          .enabled(if: xelatexAvailable, "xelatex not found"))
    func circlesAndShadingInOverlay() throws {
        let blank = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let rings = (0..<20).map { i in
            "\\draw[line width=0.6bp] ($(current page.north west)+(\(60 + i * 23) bp,-200 bp)$) circle (8bp);"
        }.joined(separator: "\n")
        let dots = (0..<20).map { i in
            "\\fill ($(current page.north west)+(\(60 + i * 23) bp,-260 bp)$) circle (3bp);"
        }.joined(separator: "\n")
        let shade = "\\shade[left color=red,right color=blue] ($(current page.north west)+(100 bp,-400 bp)$) rectangle ++(200bp,-40bp);"
        let tex = try Self.project(blank: blank, typed: rings + "\n" + dots + "\n" + shade)
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let result = try FormFiller.fill(tex: tex, output: output)
        #expect(result.passed, "\(result.report.checks.filter { $0.count > 0 })")
    }

    @Test("a character the font lacks is refused instead of silently left out",
          .enabled(if: xelatexAvailable, "xelatex not found"))
    func missingCharacter() throws {
        let tex = try Round6FixTests.cjkProject(typed: "\\at{100}{100}{12}{甲\u{2A736}乙};")
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let error = #expect(throws: FormFillError.self) {
            try FormFiller.fill(tex: tex, output: output)
        }
        guard case .missingCharacters(let characters)? = error else {
            Issue.record("expected missingCharacters, got \(String(describing: error))")
            return
        }
        #expect(characters == ["\u{2A736}"])
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("a large glyph fully on the page passes near the right margin too",
          .enabled(if: xelatexAvailable, "xelatex not found"))
    func largeGlyphNearRightMargin() throws {
        let tex = try Round6FixTests.cjkProject(typed: "\\at{500}{500}{330}{.};")
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        #expect(try FormFiller.fill(tex: tex, output: output).passed)
    }

    @Test("an included figure whose standard-14 font has no widths is accepted inside its frame",
          .enabled(if: xelatexAvailable, "xelatex not found"))
    func includedFigureWithoutWidths() throws {
        let figure = try Round5FixTests.handMadePDF(content: "BT /F2 24 Tf 1 0 0 1 100 400 Tm (Score) Tj ET 100 100 m 400 300 l S")
        defer { try? FileManager.default.removeItem(at: figure) }
        let tex = try Round6FixTests.cjkProject(
            typed: "\\node[anchor=north west,inner sep=0pt] at ($(current page.north west)+(200bp,-300bp)$) {\\includegraphics[width=150bp]{fig.pdf}};")
        try FileManager.default.copyItem(at: figure, to: tex.deletingLastPathComponent().appendingPathComponent("fig.pdf"))
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let result = try FormFiller.fill(tex: tex, output: output)
        #expect(result.passed, "\(result.report.checks.filter { $0.count > 0 })")
    }
}
