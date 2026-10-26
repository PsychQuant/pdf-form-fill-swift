import CoreGraphics
import Foundation
@testable import PDFFormFill
import PDFVisualDiff
import Testing

/// Fixes from the ninth verification round of PsychQuant/macdoc#240.
struct Round9FixTests {

    static func stampAlone(_ blank: URL) throws -> URL {
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("r9-\(UUID().uuidString).pdf")
        try FormStamper.stamp(original: blank, overlay: overlay, pageMode: .original, output: out)
        return out
    }

    @Test("a shared array is written once, not expanded at every use")
    func sharedArraysDoNotExpand() throws {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R /Resources << /Unused 5 0 R >> >>",
            Round6FixTests.stream("", "0 0 0 rg 100 100 20 20 re f"),
        ]
        for level in 0..<30 { objects.append("[\(level + 6) 0 R \(level + 6) 0 R]") }
        objects.append("[1 2 3]")
        let blank = try Round6FixTests.rawPDF(objects)
        let start = Date()
        let out = try Self.stampAlone(blank)
        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int ?? 0
        #expect(size < 1 << 20)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("a resource name with bytes outside UTF-8 keeps its bytes")
    func nameBytesRoundTrip() throws {
        let form = Round6FixTests.stream("/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "0 0 0 rg 0 0 50 50 re f")
        let blank = try Round6FixTests.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R "
                + "/Resources << /XObject << /X#E9 5 0 R >> >> >>",
            Round6FixTests.stream("", "q 1 0 0 1 100 400 cm /X#E9 Do Q"),
            form,
        ])
        let out = try Self.stampAlone(blank)
        let a = try PageRaster.render(url: blank, pageIndex: 0, dpi: 72), b = try PageRaster.render(url: out, pageIndex: 0, dpi: 72)
        #expect(a.pixels.filter { $0 < 128 }.count > 0)
        #expect(try SignedDiff(original: a, output: b).changedPixelCount == 0)
    }

    @Test("numbers read back as the same values", arguments: [
        1e-18, -0.5, 841.8897637795276, 595.2755905511812, 123456789.123, 1e20, -3.25e-7, 0.1,
    ])
    func numbersRoundTrip(value: Double) throws {
        let text = try PDFObjectWriter.number(CGFloat(value))
        #expect(!text.contains("e") && !text.contains("E"))
        #expect(Double(text) == value)
    }

    @Test("text outside a node is reported apart from characters a font lacks")
    func nullfontSeparated() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("r9-\(UUID().uuidString).log")
        try """
        Missing character: There is no ; ("3B) in font nullfont!
        Missing character: There is no x ("78) in font nullfont!
        Missing character: There is no \u{2A736} (U+2A736) in font [PingFang TC]/OT:script=hani;language=dflt;!
        Missing character: There is no \u{2460} ("2460) in font lmroman10-regular!
        """.write(to: log, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: log) }
        let dropped = OverlayCompiler.droppedCharacters(in: log)
        #expect(dropped.missing == ["\u{2A736}", "\u{2460}"])
        #expect(dropped.stray == [";", "x"])
    }

    @Test("a width table with an entry that cannot be read leaves the font unplaceable")
    func unreadableWidth() throws {
        let font = "<< /Type /Font /Subtype /Type1 /BaseFont /X /FirstChar 65 /LastChar 67 /Widths [500 (x) 500] >>"
        let result = try Round8FixTests.scan("BT /F1 12 Tf 1 0 0 1 100 400 Tm (A) Tj ET",
                                             resources: "/Font << /F1 5 0 R >>", extra: [font])
        #expect(result.undecidable > 0)
    }

    @Test("a form /Matrix that is present but not an array is unverifiable")
    func matrixNotArray() throws {
        let form = Round6FixTests.stream("/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix 5", "0 0 m 10 10 l S")
        #expect(try Round8FixTests.scan("/X0 Do", resources: "/XObject << /X0 5 0 R >>", extra: [form]).undecidable > 0)
    }

    @Test("an original that leaves q levels open does not move the overlay",
          .enabled(if: xelatexAvailable, "xelatex not found"))
    func unbalancedSaveLevels() throws {
        let blank = try Round6FixTests.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R >>",
            Round6FixTests.stream("", "q 1 0 0 1 50 50 cm q 2 0 0 2 0 0 cm 0 0 0 rg 10 10 20 20 re f"),
        ])
        defer { try? FileManager.default.removeItem(at: blank) }
        let result = try DocumentStateTests.fill(blank, typed: "\\at{40}{40}{12}{甲};")
        #expect(result.passed, "\(result.report.checks.filter { $0.count > 0 })")
    }

    @Test("an original that needs a password is reported as locked")
    func lockedOriginal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("locked-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        var media = CGRect(x: 0, y: 0, width: 595.2756, height: 841.8898)
        let info = [kCGPDFContextUserPassword as String: "secret", kCGPDFContextOwnerPassword as String: "owner"] as CFDictionary
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, info))
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 100, y: 100, width: 20, height: 20))
        context.endPDFPage()
        context.closePDF()
        #expect(throws: FormFillError.lockedPDF(url.path)) {
            try FormStamper.targetSize(original: url, pageMode: .a4)
        }
    }

    @Test("typed text left outside any node is refused instead of dropped",
          .enabled(if: xelatexAvailable, "xelatex not found"))
    func textOutsideNodeRefused() throws {
        let tex = try Round6FixTests.cjkProject(typed: "\\at{40}{40}{12}{甲}; 乙丙")
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let error = #expect(throws: FormFillError.self) {
            try FormFiller.fill(tex: tex, output: output)
        }
        guard case .textOutsideNodes(let characters)? = error else {
            Issue.record("expected textOutsideNodes, got \(String(describing: error))")
            return
        }
        #expect(characters.contains("乙"))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
