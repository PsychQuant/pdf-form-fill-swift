import CoreGraphics
import Foundation
@testable import PDFFormFill
import PDFVisualDiff
import Testing

/// Fixes from the cross-model (Codex) pass of the tenth verification round
/// of PsychQuant/macdoc#240.
struct Round10CodexFixTests {

    static func layeredOverlay() throws -> URL {
        try Round6FixTests.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R] /D << /Order [5 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R >>",
            Round6FixTests.stream("", ""),
            "<< /Type /OCG /Name (Layer) >>",
        ])
    }

    static func externalStreamOriginal() throws -> URL {
        try Round6FixTests.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R "
                + "/Resources << /XObject << /Im0 5 0 R >> >> >>",
            Round6FixTests.stream("", "0 0 0 rg 100 100 20 20 re f"),
            "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /BitsPerComponent 8 /ColorSpace /DeviceGray "
                + "/F (elsewhere.bin) /Length 0 >>\nstream\n\nendstream",
        ])
    }

    @Test("a refused stamp names its reason as a case, so a caller can word it in any language", arguments: [
        (false, StampRefusal.overlayHasLayers),
        (true, StampRefusal.externalStream),
    ])
    func structuredRefusal(externalOriginal: Bool, expected: StampRefusal) throws {
        let original = try externalOriginal ? Self.externalStreamOriginal() : SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let overlay = try externalOriginal ? SyntheticPDF.make(size: SyntheticPDF.a4, []) : Self.layeredOverlay()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("r10c-\(UUID().uuidString).pdf")
        defer { for url in [original, overlay, output] { try? FileManager.default.removeItem(at: url) } }
        #expect(throws: FormFillError.unstampable(expected)) {
            try FormStamper.stamp(original: original, overlay: overlay, pageMode: .original, output: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("the writer's budget refusal names the limit")
    func budgetRefusal() throws {
        var writer = PDFObjectWriter(budget: 10)
        let number = writer.reserve()
        #expect(throws: StampRefusal.tooLarge(limit: 10)) {
            try writer.set(number, Data(count: 11))
        }
    }

    @Test("the library's English text for a refusal still names the reason")
    func refusalDescription() {
        #expect(FormFillError.unstampable(.overlayHasLayers).description.contains("optional content"))
        #expect(StampRefusal.nestedTooDeep(limit: 64).description.contains("64"))
    }

    /// At 127 and 254 dpi an exact A4 page is 1485 and 2970 rows, but the
    /// 841.89 bp page TeX writes is one row taller, so the shared canvas has
    /// to cover the compiled overlay too (144 dpi is the control). No pixel
    /// difference from the shorter canvas has been observed on this content;
    /// the test guards the fill at the resolutions where the heights differ.
    @Test("compared renders share a height that covers the compiled overlay",
          .enabled(if: xelatexAvailable, "xelatex not found"), arguments: [127.0, 144.0, 254.0])
    func canvasCoversOverlay(dpi: Double) throws {
        let blank = try SyntheticPDF.make(size: SyntheticPDF.a4, [])
        let lines = (0..<60).map { i in
            "\\draw[line width=0.5bp] ($(current page.north west)+(40.2bp,-\(60.37 + Double(i) * 12.13 + 3.07)bp)$) -- ++(515.5bp,0);"
        }.joined(separator: "\n")
        let tex = try StampFidelityTests.project(blank: blank, typed: lines + "\n\\at{20}{30}{12}{甲};")
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        defer {
            try? FileManager.default.removeItem(at: blank)
            try? FileManager.default.removeItem(at: tex.deletingLastPathComponent())
        }
        let result = try FormFiller.fill(tex: tex, output: output, pageMode: .a4, dpi: dpi)
        #expect(result.passed, "\(result.report.checks.filter { $0.count > 0 })")
    }
}
