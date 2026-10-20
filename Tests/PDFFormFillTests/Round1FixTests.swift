import CoreGraphics
import Foundation
import PDFKit
@testable import PDFFormFill
import PDFVisualDiff
import Testing

/// Fixes from the first verification round of PsychQuant/macdoc#240.
struct Round1FixTests {

    /// A project directory with blank.pdf of `size` and filled.tex built from
    /// the generated skeleton, with `typed` placed before `\end{tikzpicture}`.
    static func skeletonProject(size: CGSize, items: [SyntheticPDF.Item] = [], typed: String) throws -> URL {
        let dir = try OverlayCompilerTests.workspace()
        let blank = dir.appendingPathComponent("blank.pdf")
        try SyntheticPDF.write([SyntheticPDF.Page(size: size, items: items)], to: blank)
        let skeleton = try FormSkeleton.generate(blankForm: blank, reference: "blank.pdf")
        let tex = dir.appendingPathComponent("filled.tex")
        try skeleton.replacingOccurrences(of: "\\end{tikzpicture}", with: "\(typed)\n\\end{tikzpicture}")
            .write(to: tex, atomically: true, encoding: .utf8)
        return tex
    }

    // MARK: inputs are never overwritten

    @Test("an output path that is the blank form is refused and the blank form is left as it was")
    func outputIsOriginal() throws {
        let tex = try FormFillerTests.project(typed: "\\at{123}{310}{12}{42};")
        let blank = tex.deletingLastPathComponent().appendingPathComponent("blank.pdf")
        let before = try Data(contentsOf: blank)
        #expect(throws: FormFillError.outputIsInput(path: blank.path, role: "blank form")) {
            try FormFiller.fill(tex: tex, output: blank)
        }
        #expect(try Data(contentsOf: blank) == before)
    }

    @Test("a symbolic link to the blank form is refused as the output")
    func outputIsLinkToOriginal() throws {
        let tex = try FormFillerTests.project(typed: "")
        let dir = tex.deletingLastPathComponent()
        let link = dir.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("blank.pdf"))
        #expect(throws: FormFillError.outputIsInput(path: link.path, role: "blank form")) {
            try FormFiller.fill(tex: tex, output: link)
        }
    }

    @Test("the .tex source is refused as the output")
    func outputIsTeX() throws {
        let tex = try FormFillerTests.project(typed: "")
        #expect(throws: FormFillError.outputIsInput(path: tex.path, role: ".tex source")) {
            try FormFiller.fill(tex: tex, output: tex)
        }
    }

    @Test("the stamper refuses to write over the original")
    func stamperRefusesOriginal() throws {
        let original = try SyntheticPDF.make(size: SyntheticPDF.a4, FormStamperTests.formItems)
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        #expect(throws: FormFillError.outputIsInput(path: original.path, role: "blank form")) {
            try FormStamper.stamp(original: original, overlay: overlay, output: original)
        }
    }

    @Test("an invalid resolution is refused before anything is written")
    func resolutionFirst() throws {
        let tex = try FormFillerTests.project(typed: "")
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        #expect(throws: PDFVisualDiffError.invalidResolution(0)) {
            try FormFiller.fill(tex: tex, output: output, dpi: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: originals a redraw cannot carry

    @Test("an original with an annotation is refused")
    func annotatedOriginal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("annotated-\(UUID().uuidString).pdf")
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        let context = try #require(CGContext(consumer: consumer, mediaBox: nil, nil))
        var box = CGRect(origin: .zero, size: SyntheticPDF.a4)
        context.beginPage(mediaBox: &box)
        context.setURL(URL(string: "https://example.com")! as CFURL, for: CGRect(x: 100, y: 100, width: 50, height: 10))
        context.endPage()
        context.closePDF()
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        #expect(throws: FormFillError.annotatedOriginal(count: 1)) {
            try FormStamper.stamp(original: url, overlay: overlay, output: FormStamperTests.output())
        }
    }

    @Test("a rotated original is refused before the overlay is compiled")
    func rotatedOriginal() throws {
        let tex = try FormFillerTests.project(typed: "")
        let blank = tex.deletingLastPathComponent().appendingPathComponent("blank.pdf")
        let document = try #require(PDFDocument(url: blank))
        document.page(at: 0)?.rotation = 90
        #expect(document.write(to: blank))
        // The engine does not exist: reaching the compiler would report that instead.
        #expect(throws: FormFillError.rotatedOriginal(degrees: 90)) {
            try FormFiller.fill(tex: tex, output: tex.deletingLastPathComponent().appendingPathComponent("out.pdf"),
                                engine: "/nonexistent/xelatex")
        }
    }

    // MARK: page sizes

    @Test("a near-A4 form stamped with an empty overlay renders like the original over the common region")
    func normalizationMovesNothing() throws {
        let original = try SyntheticPDF.make(size: SyntheticPDF.nearA4, FormStamperTests.formItems)
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let output = FormStamperTests.output()
        try FormStamper.stamp(original: original, overlay: overlay, pageMode: .a4, output: output)
        let diff = try SignedDiff(original: PageRaster.render(url: original, pageIndex: 0, dpi: 144),
                                  output: PageRaster.render(url: output, pageIndex: 0, dpi: 144))
        #expect(diff.changedPixelCount == 0)
        #expect(!diff.sizesMatch)
    }

    @Test("the overlay must have the output's page size")
    func overlaySizeMustMatch() throws {
        let original = try SyntheticPDF.make(size: SyntheticPDF.nearA4, FormStamperTests.formItems)
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let error = #expect(throws: FormFillError.self) {
            try FormStamper.stamp(original: original, overlay: overlay, pageMode: .original, output: FormStamperTests.output())
        }
        guard case let .overlayWrongSize(_, _, expectedWidth, expectedHeight)? = error else {
            Issue.record("expected overlayWrongSize, got \(String(describing: error))")
            return
        }
        #expect(expectedWidth == 596 && expectedHeight == 843)
    }

    @Test("a form larger than A4 gets a skeleton of its own size, and text beyond A4 passes in page mode original",
          .enabled(if: xelatexAvailable, "xelatex not found"))
    func largerThanA4() throws {
        let tex = try Self.skeletonProject(
            size: CGSize(width: 620, height: 900),
            items: [.line(from: CGPoint(x: 100, y: 880), to: CGPoint(x: 500, y: 880), width: 1)],
            typed: "\\at{120}{860}{12}{42};")
        let skeleton = try String(contentsOf: tex, encoding: .utf8)
        #expect(skeleton.contains("\\usepackage[paperwidth=620.0000bp,paperheight=900.0000bp,margin=0pt]{geometry}"))
        let result = try FormFiller.fill(tex: tex, output: tex.deletingLastPathComponent().appendingPathComponent("out.pdf"),
                                         pageMode: .original)
        #expect(result.passed, "\(result.report.checks.filter { $0.count > 0 })")
        #expect(result.pageSize == CGSize(width: 620, height: 900))
    }

    // MARK: skeleton

    @Test("the skeleton declares one empty field macro per label and uses it in that label's placement line")
    func fieldMacros() throws {
        let skeleton = try FormSkeleton.generate(blankForm: FormSkeletonTests.blankForm(), reference: "blank.pdf")
        let lines = skeleton.split(separator: "\n").map(String.init)
        let macros = lines.filter { $0.hasPrefix("\\newcommand{\\Field") }
        #expect(macros == [
            "\\newcommand{\\FieldA}{} % 標題",
            "\\newcommand{\\FieldB}{} % 甲",
            "\\newcommand{\\FieldC}{} % 乙",
            "\\newcommand{\\FieldD}{} % 丙",
        ])
        #expect(lines.contains { $0.hasPrefix("% \\at{") && $0.contains("{\\FieldB}; % 甲 ") })
    }

    @Test("macro names continue past Z")
    func macroNames() {
        #expect(FormSkeleton.fieldMacroName(0) == "FieldA")
        #expect(FormSkeleton.fieldMacroName(25) == "FieldZ")
        #expect(FormSkeleton.fieldMacroName(26) == "FieldAA")
        #expect(FormSkeleton.fieldMacroName(27) == "FieldAB")
    }

    @Test("a blank-form path that TeX would misread is refused",
          arguments: ["a%b.pdf", "a#b.pdf", "a{b.pdf", "a}b.pdf", "a\\b.pdf", "a^^2fb.pdf", "a\nb.pdf"])
    func unsafeReference(name: String) throws {
        #expect(throws: FormFillError.unsafeBlankFormPath(name)) {
            try FormSkeleton.generate(blankForm: FormSkeletonTests.blankForm(), reference: name)
        }
    }

    @Test("a multi-line field wraps inside its width", .enabled(if: xelatexAvailable, "xelatex not found"))
    func multiLineField() throws {
        let text = String(repeating: "填寫內容", count: 6)
        let tex = try Self.skeletonProject(size: SyntheticPDF.a4, typed: "\\atbox{100}{400}{120}{12}{\(text)};")
        let result = try FormFiller.fill(tex: tex, output: tex.deletingLastPathComponent().appendingPathComponent("out.pdf"))
        #expect(result.passed, "\(result.report.checks.filter { $0.count > 0 })")
        let output = try PageRaster.render(url: result.output, pageIndex: 0, dpi: 72)
        var inkRows = Set<Int>(), maxX = 0
        for y in 0..<output.height {
            for x in 0..<output.width where !output.isWhite(x: x, y: y) {
                inkRows.insert(y)
                maxX = max(maxX, x)
            }
        }
        // 24 characters of 12 bp do not fit in 120 bp: at least three lines.
        #expect((inkRows.max() ?? 0) - (inkRows.min() ?? 0) > 24)
        #expect(maxX <= 221)
    }

    // MARK: compiler

    @Test("the engine runs without shell escape and reads the source under a fixed name")
    func engineArguments() {
        let arguments = OverlayCompiler.engineArguments(outputDirectory: URL(fileURLWithPath: "/tmp/work"))
        #expect(arguments.contains("-no-shell-escape"))
        #expect(arguments.last == "/tmp/work/overlay.tex")
    }

    @Test("a compile that does not finish in time is stopped", .enabled(if: xelatexAvailable, "xelatex not found"))
    func timeout() throws {
        let dir = try OverlayCompilerTests.workspace()
        let tex = try OverlayCompilerTests.write("\\def\\x{\\x}\\x", in: dir)
        #expect(throws: FormFillError.compilationTimedOut(seconds: 2)) {
            try OverlayCompiler().compile(tex: tex, timeout: 2)
        }
    }

    @Test("discard removes the compiled overlay's temporary directory", .enabled(if: xelatexAvailable, "xelatex not found"))
    func discard() throws {
        let dir = try OverlayCompilerTests.workspace()
        let tex = try OverlayCompilerTests.write(OverlayCompilerTests.minimalA4, in: dir)
        let pdf = try OverlayCompiler().compile(tex: tex)
        #expect(FileManager.default.fileExists(atPath: pdf.path))
        OverlayCompiler.discard(pdf)
        #expect(!FileManager.default.fileExists(atPath: pdf.deletingLastPathComponent().path))
    }
}
