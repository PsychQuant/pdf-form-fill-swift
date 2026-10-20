import CoreGraphics
import Foundation
import PDFFormFill
import PDFVisualDiff
import Testing

struct FormFillerTests {

    /// Writes the spec's near-A4 form as blank.pdf and an overlay .tex next to it.
    static func project(typed: String, blankFormLine: String = "\\newcommand{\\BlankForm}{blank.pdf}") throws -> URL {
        let dir = try OverlayCompilerTests.workspace()
        try SyntheticPDF.write([SyntheticPDF.Page(size: SyntheticPDF.pdfMakerA4, items: FormStamperTests.formItems)],
                               to: dir.appendingPathComponent("blank.pdf"))
        return try OverlayCompilerTests.write("""
        \\documentclass{article}
        \\usepackage[a4paper,margin=0pt]{geometry}
        \\usepackage{tikz}
        \\usetikzlibrary{calc}
        \\pagestyle{empty}
        \(blankFormLine)
        \\newcommand{\\at}[3]{\\node[anchor=base west,inner sep=0pt,font=\\fontsize{#3}{#3}\\selectfont] at ($(current page.north west)+(#1 bp,-#2 bp)$)}
        \\begin{document}
        \\null
        \\begin{tikzpicture}[remember picture,overlay]
        \(typed)
        \\end{tikzpicture}
        \\end{document}
        """, in: dir, name: "filled.tex")
    }

    @Test("a clean fill passes every check and is exact A4", .enabled(if: xelatexAvailable, "xelatex not found"))
    func cleanFill() throws {
        let tex = try Self.project(typed: "\\at{180}{237.5}{12}{115};")
        let output = tex.deletingPathExtension().appendingPathExtension("pdf")
        let result = try FormFiller.fill(tex: tex, output: output)
        #expect(result.passed)
        #expect(result.output == output)
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(abs(result.pageSize.width - PageGeometry.a4.width) < 0.01)
        for check in OverlayCheck.allCases {
            #expect(result.report.result(for: check).count == 0, "\(check)")
        }
    }

    @Test("text placed over a printed label fails the fill and is located", .enabled(if: xelatexAvailable, "xelatex not found"))
    func collision() throws {
        // Same baseline as 年 (207, 227.5), starting 2 bp to its left.
        let tex = try Self.project(typed: "\\at{205}{227.5}{12}{115};")
        let output = tex.deletingPathExtension().appendingPathExtension("pdf")
        let result = try FormFiller.fill(tex: tex, output: output)
        #expect(!result.passed)
        #expect(FileManager.default.fileExists(atPath: output.path))
        let overlap = result.report.result(for: .overlayInkOnOriginalInk)
        #expect(overlap.count > 0)
        let band = try #require(overlap.bands.first)
        #expect(band.left >= 205 && band.right <= 220)
        #expect(band.top >= 214 && band.bottom <= 230)
    }

    @Test("diff artifacts are written when a directory is given", .enabled(if: xelatexAvailable, "xelatex not found"))
    func artifacts() throws {
        let tex = try Self.project(typed: "\\at{180}{237.5}{12}{115};")
        let diffDirectory = tex.deletingLastPathComponent().appendingPathComponent("diff")
        _ = try FormFiller.fill(tex: tex, output: tex.deletingPathExtension().appendingPathExtension("pdf"),
                                diffDirectory: diffDirectory)
        for name in ["diff_signed.png", "diff_abs.png", "diff.bin", "report.json"] {
            #expect(FileManager.default.fileExists(atPath: diffDirectory.appendingPathComponent(name).path), "\(name)")
        }
    }

    @Test("\\def\\BlankForm is read as well as \\newcommand")
    func defMacro() throws {
        let tex = try Self.project(typed: "", blankFormLine: "\\def\\BlankForm{blank.pdf}")
        #expect(try FormFiller.blankForm(for: tex).lastPathComponent == "blank.pdf")
    }

    @Test("a .tex without \\BlankForm is reported")
    func missingMacro() throws {
        let tex = try Self.project(typed: "", blankFormLine: "")
        #expect(throws: FormFillError.blankFormMacroMissing(tex.path)) {
            try FormFiller.blankForm(for: tex)
        }
    }

    @Test("a \\BlankForm that does not exist is reported with the resolved path")
    func missingForm() throws {
        let tex = try Self.project(typed: "", blankFormLine: "\\newcommand{\\BlankForm}{nowhere/blank.pdf}")
        let expected = tex.deletingLastPathComponent().appendingPathComponent("nowhere/blank.pdf").standardizedFileURL.path
        #expect(throws: FormFillError.blankFormNotFound(expected)) {
            try FormFiller.blankForm(for: tex)
        }
    }
}
