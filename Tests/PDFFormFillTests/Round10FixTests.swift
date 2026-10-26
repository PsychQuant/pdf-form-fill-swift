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
}
