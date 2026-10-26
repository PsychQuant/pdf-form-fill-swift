import CoreGraphics
import Foundation
@testable import PDFFormFill
import PDFVisualDiff
import Testing

/// Fixes from the tenth verification round of PsychQuant/macdoc#240.
struct Round10FixTests {

    static func output() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("r10-\(UUID().uuidString).pdf")
    }

    @Test("an overlay with layers of its own is refused and nothing is written")
    func overlayWithLayers() throws {
        let original = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let overlay = try Round6FixTests.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R] /D << /Order [5 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R >>",
            Round6FixTests.stream("", ""),
            "<< /Type /OCG /Name (Layer) >>",
        ])
        let output = Self.output()
        let error = #expect(throws: FormFillError.self) {
            try FormStamper.stamp(original: original, overlay: overlay, output: output)
        }
        guard case .unstampable? = error else {
            Issue.record("expected unstampable, got \(String(describing: error))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("an original whose objects cannot be copied is refused and nothing is written")
    func uncopyableOriginal() throws {
        let original = try Round6FixTests.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R "
                + "/Resources << /XObject << /Im0 5 0 R >> >> >>",
            Round6FixTests.stream("", "0 0 0 rg 100 100 20 20 re f"),
            "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray "
                + "/F (elsewhere.bin) /Length 0 >>\nstream\n\nendstream",
        ])
        let overlay = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let output = Self.output()
        let error = #expect(throws: FormFillError.self) {
            try FormStamper.stamp(original: original, overlay: overlay, pageMode: .original, output: output)
        }
        guard case .unstampable? = error else {
            Issue.record("expected unstampable, got \(String(describing: error))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("every body the writer keeps counts against its budget")
    func budgetBoundsEveryWrite() throws {
        var writer = PDFObjectWriter(budget: 1000)
        _ = try writer.stream(entries: [], data: Data(repeating: 0x20, count: 500))
        #expect(throws: PDFObjectWriter.Unsupported.self) {
            _ = try writer.stream(entries: [], data: Data(repeating: 0x20, count: 600))
        }
        let number = writer.reserve()
        #expect(throws: PDFObjectWriter.Unsupported.self) {
            try writer.set(number, Data(repeating: 0x20, count: 600))
        }
    }

    @Test("a long string referred to from many keys is written once")
    func sharedStringsDoNotMultiply() throws {
        let keys = (0..<300).map { "/K\($0) 5 0 R" }.joined(separator: " ")
        let long = "(" + String(repeating: "a", count: 64 * 1024) + ")"
        let blank = try Round6FixTests.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R "
                + "/Resources << /Properties << /P << \(keys) >> >> >> >>",
            Round6FixTests.stream("", "0 0 0 rg 100 100 20 20 re f"),
            long,
        ])
        defer { try? FileManager.default.removeItem(at: blank) }
        let start = Date()
        let out = try Round9FixTests.stampAlone(blank)
        let size = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int ?? 0
        #expect(size < 1 << 20)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test("page mode a4 compares on one canvas, so a faithful output of a taller page passes",
          .enabled(if: xelatexAvailable, "xelatex not found"), arguments: [144.0, 200.0])
    func oneCanvasForA4(dpi: Double) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("curves-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let consumer = try #require(CGDataConsumer(url: url as CFURL))
        var media = CGRect(x: 0, y: 0, width: 596, height: 843)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setStrokeColor(CGColor(gray: 0.4, alpha: 1))
        context.setLineWidth(0.37)
        var seed: UInt64 = 7
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for _ in 0..<300 {
            let center = CGPoint(x: 80 + next() * 436, y: 80 + next() * 683)
            let p = { CGPoint(x: center.x + next() * 40 - 20, y: center.y + next() * 40 - 20) }
            context.move(to: p())
            context.addCurve(to: p(), control1: p(), control2: p())
        }
        context.strokePath()
        context.endPDFPage()
        context.closePDF()
        let tex = try StampFidelityTests.project(blank: url, typed: "")
        let result = try FormFiller.fill(tex: tex, output: tex.deletingLastPathComponent().appendingPathComponent("out.pdf"),
                                         pageMode: .a4, dpi: dpi)
        #expect(result.passed, "\(result.report.checks.filter { $0.count > 0 })")
    }
}
