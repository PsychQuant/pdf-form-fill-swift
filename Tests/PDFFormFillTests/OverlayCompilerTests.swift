import CoreGraphics
import Foundation
import PDFFormFill
import PDFVisualDiff
import Testing

/// Engine-dependent tests are disabled, with the reason shown in the test
/// report, when no xelatex can be found.
let xelatexAvailable = OverlayCompiler.locate("xelatex") != nil

struct OverlayCompilerTests {

    static func workspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func write(_ tex: String, in dir: URL, name: String = "overlay.tex") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try tex.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static let minimalA4 = """
    \\documentclass{article}
    \\usepackage[a4paper,margin=0pt]{geometry}
    \\pagestyle{empty}
    \\begin{document}
    \\null
    \\end{document}
    """

    @Test("an engine path that does not exist is reported by name")
    func missingEngine() throws {
        let dir = try Self.workspace()
        let tex = try Self.write(Self.minimalA4, in: dir)
        let engine = "/nonexistent/\(UUID().uuidString)/xelatex"
        #expect(throws: FormFillError.engineNotFound(engine)) {
            try OverlayCompiler(engine: engine).compile(tex: tex)
        }
    }

    @Test("a freshly generated skeleton compiles unmodified to one A4 page", .enabled(if: xelatexAvailable, "xelatex not found"))
    func skeletonCompiles() throws {
        let dir = try Self.workspace()
        let form = try FormSkeletonTests.blankForm()
        let tex = try Self.write(FormSkeleton.generate(blankForm: form), in: dir)
        let pdf = try OverlayCompiler().compile(tex: tex)
        let page = try PageRaster.page(url: pdf, index: 0)
        #expect(PageGeometry.classify(page.getBoxRect(.cropBox).size) == .exactA4)
        #expect(CGPDFDocument(pdf as CFURL)?.numberOfPages == 1)
    }

    @Test("compilation leaves no files next to the source", .enabled(if: xelatexAvailable, "xelatex not found"))
    func noArtifactsNextToSource() throws {
        let dir = try Self.workspace()
        let tex = try Self.write(Self.minimalA4, in: dir)
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        _ = try OverlayCompiler().compile(tex: tex)
        let after = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(after == before)
    }

    @Test("a compile error carries the end of the log", .enabled(if: xelatexAvailable, "xelatex not found"))
    func compileErrorCarriesLog() throws {
        let dir = try Self.workspace()
        let tex = try Self.write("\\documentclass{article}\\begin{document}\\undefinedcommandxyz\\end{document}", in: dir)
        do {
            _ = try OverlayCompiler().compile(tex: tex)
            Issue.record("compilation unexpectedly succeeded")
        } catch FormFillError.compilationFailed(let logTail) {
            #expect(logTail.contains("Undefined control sequence"))
        }
    }

    @Test("an overlay that is not A4 is refused with both sizes", .enabled(if: xelatexAvailable, "xelatex not found"))
    func notA4() throws {
        let dir = try Self.workspace()
        let tex = try Self.write(Self.minimalA4.replacingOccurrences(of: "a4paper", with: "letterpaper"), in: dir)
        let error = #expect(throws: FormFillError.self) {
            try OverlayCompiler().compile(tex: tex)
        }
        guard case let .overlayWrongSize(width, height, _, _)? = error else {
            Issue.record("expected overlayWrongSize, got \(String(describing: error))")
            return
        }
        #expect(abs(width - 614.295) < 0.5 || abs(width - 612) < 0.5)
        #expect(abs(height - 794.97) < 0.5 || abs(height - 792) < 0.5)
        #expect(error?.description.contains("595.28 × 841.89") == true)
    }
}
