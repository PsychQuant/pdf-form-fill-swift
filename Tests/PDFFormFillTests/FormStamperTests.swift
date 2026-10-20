import CoreGraphics
import Foundation
import PDFFormFill
import PDFVisualDiff
import Testing

struct FormStamperTests {

    // The spec example: a near-A4 blank form with one line and the label 甲.
    static let formItems: [SyntheticPDF.Item] = [
        .line(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100), width: 1),
        .text("甲", at: CGPoint(x: 150, y: 300), size: 12, font: "PingFang TC"),
    ]

    static func output() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("stamped-\(UUID().uuidString).pdf")
    }

    static func verify(original: URL, output: URL, overlay: URL) throws -> OverlayReport {
        try OverlayVerifier.verify(
            original: PageRaster.render(url: original, pageIndex: 0, dpi: 144),
            output: PageRaster.render(url: output, pageIndex: 0, dpi: 144),
            overlay: PageRaster.render(url: overlay, pageIndex: 0, dpi: 144)).report
    }

    @Test("a near-A4 form becomes exact A4 without moving the form")
    func nearA4ToA4() throws {
        let original = try SyntheticPDF.make(size: SyntheticPDF.nearA4, Self.formItems)
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [
            .text("42", at: CGPoint(x: 123, y: 310), size: 12, font: "Helvetica"),
        ])
        let output = Self.output()
        try FormStamper.stamp(original: original, overlay: overlay, pageMode: .a4, output: output)

        let size = try PageRaster.page(url: output, index: 0).getBoxRect(.cropBox).size
        #expect(abs(size.width - PageGeometry.a4.width) < 0.01)
        #expect(abs(size.height - PageGeometry.a4.height) < 0.01)
        let report = try Self.verify(original: original, output: output, overlay: overlay)
        #expect(report.result(for: .differenceOutsideOverlay).count == 0)
        #expect(report.result(for: .originalMadeLighter).count == 0)
        #expect(report.result(for: .inkInCroppedStrip).count == 0)
        #expect(report.changedPixelCount > 0)
    }

    @Test("page mode original keeps the original size")
    func keepOriginalSize() throws {
        let original = try SyntheticPDF.make(size: SyntheticPDF.nearA4, Self.formItems)
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.nearA4, [
            .text("42", at: CGPoint(x: 123, y: 310), size: 12, font: "Helvetica"),
        ])
        let output = Self.output()
        try FormStamper.stamp(original: original, overlay: overlay, pageMode: .original, output: output)
        let size = try PageRaster.page(url: output, index: 0).getBoxRect(.cropBox).size
        #expect(abs(size.width - 596) < 0.01)
        #expect(abs(size.height - 843) < 0.01)
        #expect(try Self.verify(original: original, output: output, overlay: overlay).passed)
    }

    @Test("a TeX-compiled overlay stamps with zero difference outside it", .enabled(if: xelatexAvailable, "xelatex not found"))
    func texOverlay() throws {
        let original = try SyntheticPDF.make(size: SyntheticPDF.nearA4, Self.formItems)
        let dir = try OverlayCompilerTests.workspace()
        let tex = try OverlayCompilerTests.write("""
        \\documentclass{article}
        \\usepackage[a4paper,margin=0pt]{geometry}
        \\usepackage{tikz}
        \\usetikzlibrary{calc}
        \\pagestyle{empty}
        \\newcommand{\\at}[3]{\\node[anchor=base west,inner sep=0pt,font=\\fontsize{#3}{#3}\\selectfont] at ($(current page.north west)+(#1 bp,-#2 bp)$)}
        \\begin{document}
        \\null
        \\begin{tikzpicture}[remember picture,overlay]
        \\at{123}{310}{12}{42};
        \\end{tikzpicture}
        \\end{document}
        """, in: dir)
        let overlay = try OverlayCompiler().compile(tex: tex)
        defer { OverlayCompiler.discard(overlay) }
        let output = Self.output()
        try FormStamper.stamp(original: original, overlay: overlay, pageMode: .a4, output: output)
        let report = try Self.verify(original: original, output: output, overlay: overlay)
        for check in OverlayCheck.allCases {
            #expect(report.result(for: check).count == 0, "\(check)")
        }
        #expect(report.changedPixelCount > 0)
    }

    @Test("the original file is never modified")
    func originalUntouched() throws {
        let original = try SyntheticPDF.make(size: SyntheticPDF.nearA4, Self.formItems)
        let before = try Data(contentsOf: original)
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        try FormStamper.stamp(original: original, overlay: overlay, pageMode: .a4, output: Self.output())
        #expect(try Data(contentsOf: original) == before)
    }

    @Test("a two-page original is rejected with its page count")
    func multiPage() throws {
        let original = try SyntheticPDF.make([
            SyntheticPDF.Page(size: SyntheticPDF.a4, items: []),
            SyntheticPDF.Page(size: SyntheticPDF.a4, items: []),
        ])
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        #expect(throws: FormFillError.multiPageOriginal(pages: 2)) {
            try FormStamper.stamp(original: original, overlay: overlay, pageMode: .a4, output: Self.output())
        }
    }

    @Test("A4 mode refuses an original that is not near A4")
    func notNearA4() throws {
        let original = try SyntheticPDF.make(size: CGSize(width: 612, height: 792), [])
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        #expect(throws: FormFillError.notNearA4(width: 612, height: 792)) {
            try FormStamper.stamp(original: original, overlay: overlay, pageMode: .a4, output: Self.output())
        }
    }

    @Test("A4 mode refuses to crop ink of the original")
    func inkInStrip() throws {
        let original = try SyntheticPDF.make(size: SyntheticPDF.nearA4, [
            .line(from: CGPoint(x: 10, y: 841.95), to: CGPoint(x: 300, y: 841.95), width: 1),
        ])
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let output = Self.output()
        let error = #expect(throws: FormFillError.self) {
            try FormStamper.stamp(original: original, overlay: overlay, pageMode: .a4, output: output)
        }
        guard case .inkInRemovedStrip(let pixels)? = error else {
            Issue.record("expected inkInRemovedStrip, got \(String(describing: error))")
            return
        }
        #expect(pixels > 0)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
