import CoreGraphics
import Foundation
import PDFKit
@testable import PDFFormFill
import PDFVisualDiff
import Testing

/// Fixes from the second verification round of PsychQuant/macdoc#240.
struct Round2FixTests {

    static func contents(of dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    // MARK: the output must be a file

    @Test("a directory given as the output is refused and left as it was")
    func outputIsDirectory() throws {
        let tex = try FormFillerTests.project(typed: "")
        let target = tex.deletingLastPathComponent().appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))
        #expect(throws: FormFillError.outputNotAFile(path: target.path)) {
            try FormFiller.fill(tex: tex, output: target)
        }
        #expect(try Self.contents(of: target) == ["keep.txt"])
    }

    @Test("the .tex's own directory given as the output is refused and nothing in it changes")
    func outputIsProjectDirectory() throws {
        let tex = try FormFillerTests.project(typed: "")
        let dir = tex.deletingLastPathComponent()
        let before = try Self.contents(of: dir)
        #expect(throws: FormFillError.outputNotAFile(path: dir.path)) {
            try FormFiller.fill(tex: tex, output: dir)
        }
        #expect(try Self.contents(of: dir) == before)
    }

    @Test("the stamper refuses a directory as the output")
    func stamperRefusesDirectory() throws {
        let original = try SyntheticPDF.make(size: SyntheticPDF.a4, FormStamperTests.formItems)
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let dir = try OverlayCompilerTests.workspace()
        #expect(throws: FormFillError.outputNotAFile(path: dir.path)) {
            try FormStamper.stamp(original: original, overlay: overlay, output: dir)
        }
    }

    @Test("a symbolic link given as the output is refused, and the file it points to is untouched")
    func outputIsLink() throws {
        let tex = try FormFillerTests.project(typed: "")
        let dir = tex.deletingLastPathComponent()
        let other = dir.appendingPathComponent("other.pdf")
        try Data("keep".utf8).write(to: other)
        let link = dir.appendingPathComponent("out.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        #expect(throws: FormFillError.outputNotAFile(path: link.path)) {
            try FormFiller.fill(tex: tex, output: link)
        }
        #expect(try Data(contentsOf: other) == Data("keep".utf8))
    }

    // MARK: temporary directories

    @Test("discard leaves a directory alone unless it is one of the compiler's own in the temporary directory")
    func discardIsNarrow() throws {
        let dir = try OverlayCompilerTests.workspace()
        let lookalike = dir.appendingPathComponent("\(OverlayCompiler.directoryPrefix)lookalike", isDirectory: true)
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
        let pdf = lookalike.appendingPathComponent("overlay.pdf")
        try Data().write(to: pdf)
        OverlayCompiler.discard(pdf)
        #expect(FileManager.default.fileExists(atPath: pdf.path))
    }

    @Test("a timeout that is not a positive finite number is refused", arguments: [-1, 0, Double.nan, Double.infinity])
    func invalidTimeout(timeout: Double) throws {
        let dir = try OverlayCompilerTests.workspace()
        let tex = try OverlayCompilerTests.write(OverlayCompilerTests.minimalA4, in: dir)
        let error = #expect(throws: FormFillError.self) {
            try OverlayCompiler().compile(tex: tex, timeout: timeout)
        }
        guard case .invalidTimeout? = error else {
            Issue.record("expected invalidTimeout, got \(String(describing: error))")
            return
        }
    }

    // MARK: overlay problems found before writing

    @Test("a rotated overlay is refused before the output is written")
    func rotatedOverlay() throws {
        let original = try SyntheticPDF.make(size: SyntheticPDF.a4, FormStamperTests.formItems)
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let document = try #require(PDFDocument(url: overlay))
        document.page(at: 0)?.rotation = 90
        #expect(document.write(to: overlay))
        let output = FormStamperTests.output()
        #expect(throws: FormFillError.rotatedOverlay(degrees: 90)) {
            try FormStamper.stamp(original: original, overlay: overlay, output: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("typed text that runs past the page edge is refused", .enabled(if: xelatexAvailable, "xelatex not found"))
    func inkOffPage() throws {
        let tex = try FormFillerTests.project(typed: "\\at{580}{400}{12}{WWWWWWWW};")
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let error = #expect(throws: FormFillError.self) {
            try FormFiller.fill(tex: tex, output: output)
        }
        guard case .overlayInkOffPage? = error else {
            Issue.record("expected overlayInkOffPage, got \(String(describing: error))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: symbolic links to the .tex

    @Test("a .tex reached through a relative symbolic link fills like the file itself", .enabled(if: xelatexAvailable, "xelatex not found"))
    func texThroughLink() throws {
        let tex = try FormFillerTests.project(typed: "\\at{123}{310}{12}{42};")
        let work = tex.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let link = work.appendingPathComponent("filled.tex")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: "../\(tex.deletingLastPathComponent().lastPathComponent)/filled.tex")
        let result = try FormFiller.fill(tex: link, output: work.appendingPathComponent("out.pdf"))
        #expect(result.passed)
    }

    // MARK: crop box

    @Test("content outside the original's crop box does not reach the output")
    func cropBoxClip() throws {
        // A 595 × 841 bp crop box (near A4, smaller than A4) inside a larger media box,
        // with ink in the media box just right of the crop box.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cropped-\(UUID().uuidString).pdf")
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        var media = CGRect(x: 0, y: 0, width: 700, height: 900)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        let crop = CGRect(x: 0, y: 59, width: 595, height: 841)
        var cropBox = crop
        let info = [kCGPDFContextCropBox as String: Data(bytes: &cropBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
        context.beginPDFPage(info)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 595, y: 0, width: 5, height: 900))
        context.endPDFPage()
        context.closePDF()
        #expect(try PageRaster.page(url: url, index: 0).getBoxRect(.cropBox) == crop)

        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let output = FormStamperTests.output()
        try FormStamper.stamp(original: url, overlay: overlay, pageMode: .a4, output: output)
        let report = try OverlayVerifier.verify(
            original: PageRaster.render(url: url, pageIndex: 0, dpi: 144),
            output: PageRaster.render(url: output, pageIndex: 0, dpi: 144),
            overlay: PageRaster.render(url: overlay, pageIndex: 0, dpi: 144)).report
        #expect(report.passed, "\(report.checks.filter { $0.count > 0 })")
    }

    // MARK: skeleton

    @Test("a control character in the form's file name cannot end the header comment")
    func headerControlCharacter() throws {
        let dir = try OverlayCompilerTests.workspace()
        let form = dir.appendingPathComponent("a\nb.pdf")
        try FileManager.default.copyItem(at: FormSkeletonTests.blankForm(), to: form)
        let skeleton = try FormSkeleton.generate(blankForm: form, reference: "blank.pdf")
        #expect(skeleton.split(separator: "\n").first == "% Overlay for a?b.pdf, generated by pdf-form-fill-swift.")
    }

    @Test("a form larger than A4 gets a skeleton page of its own size")
    func skeletonOwnSize() throws {
        let form = try SyntheticPDF.make(size: CGSize(width: 620, height: 900), [])
        let skeleton = try FormSkeleton.generate(blankForm: form, reference: "blank.pdf")
        #expect(skeleton.contains("\\usepackage[paperwidth=620.0000bp,paperheight=900.0000bp,margin=0pt]{geometry}"))
        #expect(skeleton.contains("page mode original"))
    }
}
