import CoreGraphics
import Foundation
@testable import PDFFormFill
import PDFVisualDiff
import Testing

/// Stamping keeps what the original document says about how its page is
/// shown (verification round 9 of PsychQuant/macdoc#240).
struct DocumentStateTests {

    static func fill(_ blank: URL, typed: String) throws -> FillResult {
        let tex = try StampFidelityTests.project(blank: blank, typed: typed)
        return try FormFiller.fill(tex: tex, output: tex.deletingLastPathComponent().appendingPathComponent("out.pdf"))
    }

    @Test("a layer the original hides stays hidden", .enabled(if: xelatexAvailable, "xelatex not found"))
    func hiddenLayerStaysHidden() throws {
        let content = "/OC /oc1 BDC 0 0 0 rg 100 100 200 200 re f EMC 0 0 0 rg 300 600 20 20 re f"
        let blank = try Round6FixTests.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R] /D << /OFF [5 0 R] /Order [5 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R "
                + "/Resources << /Properties << /oc1 5 0 R >> >> >>",
            Round6FixTests.stream("", content),
            "<< /Type /OCG /Name (Layer) >>",
        ])
        defer { try? FileManager.default.removeItem(at: blank) }
        let result = try Self.fill(blank, typed: "\\at{40}{40}{12}{甲};")
        #expect(result.passed, "\(result.report.checks.filter { $0.count > 0 })")
    }

    @Test("an overlay in colour is not blended in the original's CMYK page group",
          .enabled(if: xelatexAvailable, "xelatex not found"))
    func pageGroupDoesNotTakeInOverlay() throws {
        let content = "/G0 gs 0.2 0.6 0 0 k 100 100 200 200 re f 0 0.5 0.5 0 k 200 150 200 200 re f"
        let blank = try Round6FixTests.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R "
                + "/Group << /S /Transparency /CS /DeviceCMYK /I true >> /Resources << /ExtGState << /G0 << /ca 0.5 >> >> >> >>",
            Round6FixTests.stream("", content),
        ])
        defer { try? FileManager.default.removeItem(at: blank) }
        let result = try Self.fill(blank, typed: "\\at{40}{40}{14}{\\color{red}甲乙 AB};\n\\at{40}{80}{14}{\\color{blue}丙丁 CD};\n\\at{40}{120}{14}{戊己 EF};\n\\fill[red,opacity=0.5] ($(current page.north west)+(60bp,-200bp)$) rectangle ++(80bp,-40bp);\n\\fill[green!60!black,opacity=0.3] ($(current page.north west)+(100bp,-210bp)$) circle (20bp);")
        #expect(result.passed, "\(result.report.checks.filter { $0.count > 0 })")
    }
}
