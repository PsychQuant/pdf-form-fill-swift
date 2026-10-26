import CoreGraphics
import Foundation
@testable import PDFFormFill
import PDFVisualDiff
import Testing

/// Fixes from the fourth verification round of PsychQuant/macdoc#240.
struct Round4FixTests {

    @Test("a field placed far off the page is refused, however far", .enabled(if: xelatexAvailable, "xelatex not found"),
          arguments: ["\\at{3000}{78}{10}{2026};", "\\at{-700}{100}{10}{X};", "\\at{100}{1800}{10}{Y};"])
    func fieldFarOffPage(typed: String) throws {
        let tex = try FormFillerTests.project(typed: "\\at{123}{310}{12}{42};\n" + typed)
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let error = #expect(throws: FormFillError.self) {
            try FormFiller.fill(tex: tex, output: output)
        }
        guard case .overlayTextOffPage? = error else {
            Issue.record("expected overlayTextOffPage, got \(String(describing: error))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("a timed-out compile also stops descendants orphaned by an exited child")
    func timeoutStopsOrphans() throws {
        let dir = try OverlayCompilerTests.workspace()
        let pidFile = dir.appendingPathComponent("orphan.pid")
        let engine = dir.appendingPathComponent("fake-engine")
        try """
        #!/bin/sh
        sh -c 'sleep 300 & echo $! > "\(pidFile.path)"'
        sleep 300
        """.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        let tex = try OverlayCompilerTests.write(OverlayCompilerTests.minimalA4, in: dir)
        #expect(throws: FormFillError.compilationTimedOut(seconds: 2)) {
            try OverlayCompiler(engine: engine.path).compile(tex: tex, timeout: 2)
        }
        let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        usleep(200_000)
        #expect(kill(pid, 0) != 0, "orphan \(pid) is still running")
    }

    @Test("an output that differs from an artifact only in case is refused")
    func artifactCaseVariant() throws {
        let tex = try FormFillerTests.project(typed: "")
        let diff = tex.deletingLastPathComponent().appendingPathComponent("diff", isDirectory: true)
        #expect(throws: FormFillError.diffArtifactCollides(path: diff.appendingPathComponent("report.json").path, role: "output")) {
            try FormFiller.fill(tex: tex, output: diff.appendingPathComponent("Report.json"), diffDirectory: diff)
        }
    }

    @Test("a diff directory reached through a symbolic link is checked against the output")
    func artifactThroughLinkedDirectory() throws {
        let tex = try FormFillerTests.project(typed: "")
        let dir = tex.deletingLastPathComponent()
        let link = dir.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        let error = #expect(throws: FormFillError.self) {
            try FormFiller.fill(tex: tex, output: dir.appendingPathComponent("report.json"), diffDirectory: link)
        }
        guard case .diffArtifactCollides? = error else {
            Issue.record("expected diffArtifactCollides, got \(String(describing: error))")
            return
        }
    }

    @Test("replacing an existing output keeps its permissions")
    func outputPermissionsKept() throws {
        let original = try SyntheticPDF.make(size: SyntheticPDF.a4, FormStamperTests.formItems)
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let output = try OverlayCompilerTests.workspace().appendingPathComponent("out.pdf")
        try Data("old".utf8).write(to: output)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        try FormStamper.stamp(original: original, overlay: overlay, output: output)
        let mode = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test("control characters in label text are replaced in the skeleton")
    func labelControlCharacters() {
        #expect(FormSkeleton.printable("a\u{1b}[31mb\u{7}") == "a?[31mb?")
        #expect(FormSkeleton.printable("a\u{2028}b\u{2029}c\u{85}d") == "a?b?c?d")
    }
}

/// The content-stream scan behind the far-off-page refusal.
struct ContentExtentTests {

    @Test("drawing far off the page is found from the content stream", arguments: [
        ([SyntheticPDF.Item.text("2026", at: CGPoint(x: 3000, y: 78), size: 10, font: "Helvetica")], true),
        ([SyntheticPDF.Item.fill(CGRect(x: 100, y: -2000, width: 5, height: 5))], true),
        ([SyntheticPDF.Item.text("2026", at: CGPoint(x: 100, y: 78), size: 10, font: "Helvetica")], false),
        ([SyntheticPDF.Item.fill(CGRect(x: 650, y: 100, width: 5, height: 5))], false),
        ([SyntheticPDF.Item.fill(CGRect(x: 1500, y: 100, width: 5, height: 5))], true),
        ([SyntheticPDF.Item.fill(CGRect(x: 500, y: 100, width: 5, height: 5))], false),
    ])
    func farDrawing(items: [SyntheticPDF.Item], far: Bool) throws {
        let page = try PageRaster.page(url: SyntheticPDF.make(size: SyntheticPDF.a4, items), index: 0)
        #expect((ContentExtent.scan(page: page).outside > 0) == far)
    }
}
