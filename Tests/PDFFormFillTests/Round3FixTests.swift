import CoreGraphics
import Foundation
@testable import PDFFormFill
import PDFVisualDiff
import Testing

/// Fixes from the third verification round of PsychQuant/macdoc#240.
struct Round3FixTests {

    // MARK: diff artifacts never replace an input or the output

    @Test("a diff directory whose report.json is the output is refused before anything is written")
    func artifactIsOutput() throws {
        let tex = try FormFillerTests.project(typed: "")
        let diff = tex.deletingLastPathComponent().appendingPathComponent("diff", isDirectory: true)
        let output = diff.appendingPathComponent("report.json")
        let error = #expect(throws: FormFillError.self) {
            try FormFiller.fill(tex: tex, output: output, diffDirectory: diff)
        }
        guard case let .diffArtifactCollides(path, role)? = error else {
            Issue.record("expected diffArtifactCollides, got \(String(describing: error))")
            return
        }
        #expect(path == output.path && role == "output")
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("a diff directory holding the blank form under an artifact's name is refused and the form is untouched")
    func artifactIsBlankForm() throws {
        let tex = try FormFillerTests.project(typed: "", blankFormLine: "\\newcommand{\\BlankForm}{report.json}")
        let dir = tex.deletingLastPathComponent()
        try FileManager.default.copyItem(at: dir.appendingPathComponent("blank.pdf"), to: dir.appendingPathComponent("report.json"))
        let before = try Data(contentsOf: dir.appendingPathComponent("report.json"))
        let error = #expect(throws: FormFillError.self) {
            try FormFiller.fill(tex: tex, output: dir.appendingPathComponent("out.pdf"), diffDirectory: dir)
        }
        guard case let .diffArtifactCollides(_, role)? = error else {
            Issue.record("expected diffArtifactCollides, got \(String(describing: error))")
            return
        }
        #expect(role == "blank form")
        #expect(try Data(contentsOf: dir.appendingPathComponent("report.json")) == before)
    }

    // MARK: temporary directories

    @Test("discard leaves a lookalike directory in the temporary directory alone")
    func discardOwnsOnlyItsOwn() throws {
        let lookalike = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(OverlayCompiler.directoryPrefix)unrelated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: lookalike, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lookalike) }
        try Data().write(to: lookalike.appendingPathComponent("overlay.tex"))
        try Data().write(to: lookalike.appendingPathComponent("overlay.pdf"))
        OverlayCompiler.discard(lookalike.appendingPathComponent("overlay.pdf"))
        #expect(FileManager.default.fileExists(atPath: lookalike.appendingPathComponent("overlay.tex").path))
    }

    @Test("the compile directory is private to the user", .enabled(if: xelatexAvailable, "xelatex not found"))
    func privateDirectory() throws {
        let tex = try OverlayCompilerTests.write(OverlayCompilerTests.minimalA4, in: OverlayCompilerTests.workspace())
        let pdf = try OverlayCompiler().compile(tex: tex)
        defer { OverlayCompiler.discard(pdf) }
        let attributes = try FileManager.default.attributesOfItem(atPath: pdf.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test("a timed-out compile stops the engine's whole process tree")
    func timeoutStopsGrandchildren() throws {
        let dir = try OverlayCompilerTests.workspace()
        let pidFile = dir.appendingPathComponent("grandchild.pid")
        let engine = dir.appendingPathComponent("fake-engine")
        try """
        #!/bin/sh
        sh -c 'sleep 300 & echo $! > "\(pidFile.path)"; wait' &
        wait
        """.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        let tex = try OverlayCompilerTests.write(OverlayCompilerTests.minimalA4, in: dir)
        #expect(throws: FormFillError.compilationTimedOut(seconds: 2)) {
            try OverlayCompiler(engine: engine.path).compile(tex: tex, timeout: 2)
        }
        let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        usleep(200_000)
        #expect(kill(pid, 0) != 0, "grandchild \(pid) is still running")
    }

    // MARK: writing the output

    @Test("an output name close to the file-system limit can be written")
    func longOutputName() throws {
        let original = try SyntheticPDF.make(size: SyntheticPDF.a4, FormStamperTests.formItems)
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let name = String(repeating: "填", count: 80) + ".pdf"  // 244 bytes
        let output = try OverlayCompilerTests.workspace().appendingPathComponent(name)
        try FormStamper.stamp(original: original, overlay: overlay, output: output)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test("moving the output into place never replaces a directory")
    func renameRefusesDirectory() throws {
        let dir = try OverlayCompilerTests.workspace()
        let target = dir.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("keep.txt"))
        let temporary = dir.appendingPathComponent("temp.pdf")
        try Data("pdf".utf8).write(to: temporary)
        #expect(throws: FormFillError.outputNotAFile(path: target.path)) {
            try FormStamper.moveIntoPlace(temporary, to: target)
        }
        #expect(try Data(contentsOf: target.appendingPathComponent("keep.txt")) == Data("keep".utf8))
    }

    // MARK: accurate errors

    @Test("a .tex that cannot be read is reported as such", arguments: [false, true])
    func unreadableSource(throughCompiler: Bool) throws {
        let dir = try OverlayCompilerTests.workspace()
        #expect(throws: FormFillError.unreadableSource(dir.path)) {
            if throughCompiler {
                _ = try OverlayCompiler(engine: "/bin/sh").compile(tex: dir)
            } else {
                _ = try FormFiller.blankForm(for: dir)
            }
        }
    }
}
