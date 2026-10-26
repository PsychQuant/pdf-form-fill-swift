import CoreGraphics
import Foundation
@testable import PDFFormFill
import PDFVisualDiff
import Testing

/// Fixes from the eighth verification round of PsychQuant/macdoc#240.
struct Round8FixTests {

    static let widths = Array(repeating: "500", count: 95).joined(separator: " ")
    static let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 32 /LastChar 126 /Widths [\(widths)] >>"

    /// One page with `resources` (a resource dictionary body) and `content`,
    /// followed by `extra` objects numbered from 5.
    static func scan(_ content: String, resources: String, extra: [String] = []) throws -> ContentExtent.Result {
        let url = try Round6FixTests.rawPDF([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.2756 841.8898] /Contents 4 0 R /Resources << \(resources) >> >>",
            Round6FixTests.stream("", content),
        ] + extra)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Round5FixTests.scan(url)
    }

    @Test("a glyph is bounded by its font's FontBBox, so a large glyph on the page is not reported")
    func fontBBoxBoundsGlyph() throws {
        let boxed = "<< /Type /Font /Subtype /Type1 /BaseFont /X /FirstChar 32 /LastChar 126 /Widths [\(Self.widths)] "
            + "/FontDescriptor << /Type /FontDescriptor /FontBBox [0 -200 500 700] >> >>"
        let content = "BT /F1 600 Tf 1 0 0 1 100 400 Tm (.) Tj ET"
        #expect(try Self.scan(content, resources: "/Font << /F1 5 0 R >>", extra: [boxed]) == ContentExtent.Result())
        // The em-box fallback (no FontBBox) reaches 1300 bp and is reported.
        #expect(try Self.scan(content, resources: "/Font << /F1 5 0 R >>", extra: [Self.font]).outside > 0)
    }

    @Test("text without width data under a clip within reach is accepted")
    func unplaceableTextUnderClip() throws {
        let noWidths = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        let resources = "/Font << /F2 5 0 R >>"
        #expect(try Self.scan("q 100 100 200 50 re W n BT /F2 12 Tf 1 0 0 1 110 110 Tm (A) Tj ET Q",
                              resources: resources, extra: [noWidths]) == ContentExtent.Result())
        #expect(try Self.scan("BT /F2 12 Tf 1 0 0 1 110 110 Tm (A) Tj ET",
                              resources: resources, extra: [noWidths]).undecidable > 0)
    }

    @Test("a shading is placed by its bounding box, or is unverifiable without one")
    func shading() throws {
        let onPage = "<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 1 0] /BBox [100 100 200 200] "
            + "/Function << /FunctionType 2 /Domain [0 1] /N 1 >> >>"
        let far = "<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 1 0] /BBox [5000 100 5100 200] "
            + "/Function << /FunctionType 2 /Domain [0 1] /N 1 >> >>"
        let unbounded = "<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 1 0] "
            + "/Function << /FunctionType 2 /Domain [0 1] /N 1 >> >>"
        let resources = "/Shading << /Sh0 5 0 R >>"
        #expect(try Self.scan("/Sh0 sh", resources: resources, extra: [onPage]) == ContentExtent.Result())
        #expect(try Self.scan("/Sh0 sh", resources: resources, extra: [far]).outside > 0)
        #expect(try Self.scan("/Sh0 sh", resources: resources, extra: [unbounded]).undecidable > 0)
        #expect(try Self.scan("q 100 100 50 50 re W n /Sh0 sh Q", resources: resources, extra: [unbounded])
                == ContentExtent.Result())
        #expect(try Self.scan("/Nope sh", resources: resources, extra: [onPage]).undecidable > 0)
    }

    @Test("a TJ element that is neither a number nor a string is unverifiable")
    func tjOddElement() throws {
        #expect(try Self.scan("BT /F1 12 Tf 1 0 0 1 100 400 Tm [(A) /Name (B)] TJ ET",
                              resources: "/Font << /F1 5 0 R >>", extra: [Self.font]).undecidable > 0)
    }

    @Test("a form matrix that cannot be read is unverifiable")
    func badFormMatrix() throws {
        let form = Round6FixTests.stream("/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix [1 0 0 1 0]",
                                         "0 0 m 10 10 l S")
        #expect(try Self.scan("/X0 Do", resources: "/XObject << /X0 5 0 R >>", extra: [form]).undecidable > 0)
    }

    /// `count` forms chained X0 → X1 → … each drawing on the page.
    static func chain(_ count: Int) throws -> ContentExtent.Result {
        var forms: [String] = []
        for i in 0..<count {
            let next = i + 1 < count ? "/X\(i + 1) Do " : ""
            let resources = i + 1 < count ? "/Resources << /XObject << /X\(i + 1) \(i + 6) 0 R >> >>" : "/Resources << >>"
            forms.append(Round6FixTests.stream("/Type /XObject /Subtype /Form /BBox [0 0 100 100] \(resources)",
                                               "\(next)10 10 m 20 20 l S"))
        }
        return try Self.scan("/X0 Do", resources: "/XObject << /X0 5 0 R >>", extra: forms)
    }

    @Test("forms nest up to 16 deep; the 17th is unverifiable")
    func depthBoundary() throws {
        #expect(try Self.chain(16) == ContentExtent.Result())
        #expect(try Self.chain(17).undecidable == 1)
    }

    /// `count` distinct forms, each drawn once from the page.
    static func distinct(_ count: Int) throws -> ContentExtent.Result {
        let names = (0..<count).map { "/X\($0) \($0 + 5) 0 R" }.joined(separator: " ")
        let content = (0..<count).map { "/X\($0) Do" }.joined(separator: " ")
        let forms = (0..<count).map { _ in
            Round6FixTests.stream("/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "10 10 m 20 20 l S")
        }
        return try Self.scan(content, resources: "/XObject << \(names) >>", extra: forms)
    }

    @Test("2000 distinct forms are read; the 2001st is unverifiable")
    func distinctFormBoundary() throws {
        #expect(try Self.distinct(2000) == ContentExtent.Result())
        #expect(try Self.distinct(2001).undecidable == 1)
    }

    @Test("100000 form invocations are read; the 100001st is unverifiable")
    func invocationBoundary() throws {
        let form = Round6FixTests.stream("/Type /XObject /Subtype /Form /BBox [0 0 100 100]", "10 10 m 20 20 l S")
        let resources = "/XObject << /X0 5 0 R >>"
        #expect(try Self.scan(String(repeating: "/X0 Do ", count: 100_000), resources: resources, extra: [form])
                == ContentExtent.Result())
        #expect(try Self.scan(String(repeating: "/X0 Do ", count: 100_001), resources: resources, extra: [form])
                .undecidable == 1)
    }

    @Test("the reach is 0.9 of a page: a point at 0.85 page off is left to the pixel check, at 0.95 it is reported",
          arguments: [(0.85, false), (0.95, true)])
    func reachBoundary(fraction: Double, reported: Bool) throws {
        let width = 595.2756, height = 841.8898
        let x = width + fraction * width, y = height + fraction * height
        let right = try Self.scan("100 400 m \(x) 400 l S", resources: "")
        let top = try Self.scan("100 400 m 100 \(y) l S", resources: "")
        #expect((right.outside > 0) == reported)
        #expect((top.outside > 0) == reported)
    }

    @Test("text in a Type3 font cannot be placed")
    func type3Unplaceable() throws {
        let type3 = "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 1000 1000] /FontMatrix [0.001 0 0 0.001 0 0] "
            + "/FirstChar 97 /LastChar 97 /Widths [1000] /Encoding << /Differences [97 /a] >> /CharProcs << /a 6 0 R >> >>"
        let glyph = Round6FixTests.stream("", "1000 0 d0 1300000 0 100 100 re f")
        let result = try Self.scan("BT /T3 12 Tf 1 0 0 1 100 400 Tm (a) Tj ET", resources: "/Font << /T3 5 0 R >>",
                                   extra: [type3, glyph])
        #expect(result.undecidable > 0)
    }

    @Test("a clip with no path is ignored, as renderers ignore it")
    func emptyClip() throws {
        #expect(try Self.scan("W n 0 0 0 rg 100000 100 50 50 re f", resources: "").outside > 0)
        #expect(try Self.scan("q W n 0 0 0 rg 100000 100 50 50 re f Q", resources: "").outside > 0)
    }

    @Test("width tables starting at extreme codes do not crash the scan", arguments: [
        "<< /Type /Font /Subtype /Type1 /BaseFont /X /FirstChar 9223372036854775807 /Widths [500 500] >>",
        "<< /Type /Font /Subtype /Type0 /BaseFont /X /Encoding /Identity-H /DescendantFonts [<< /Type /Font "
            + "/Subtype /CIDFontType2 /BaseFont /X /W [9223372036854775807 [500 500] -5 [500]] >>] >>",
    ])
    func extremeWidthCodes(font: String) throws {
        let result = try Self.scan("BT /F1 12 Tf 1 0 0 1 100 400 Tm (AB) Tj ET", resources: "/Font << /F1 5 0 R >>",
                                   extra: [font])
        #expect(result.outside == 0)
    }

    @Test("form-fill refuses an overlay it cannot place as unverifiable", .enabled(if: xelatexAvailable, "xelatex not found"))
    func unverifiableOverlayFill() throws {
        let tex = try Round6FixTests.cjkProject(typed: "\\at{100}{100}{12}{\\special{pdf:content /Nope Do}X};")
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let error = #expect(throws: FormFillError.self) {
            try FormFiller.fill(tex: tex, output: output)
        }
        guard case .overlayUnverifiable? = error else {
            Issue.record("expected overlayUnverifiable, got \(String(describing: error))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("a full stop set at 600 bp near the left margin is filled", .enabled(if: xelatexAvailable, "xelatex not found"))
    func largerPointSizeFill() throws {
        let tex = try Round6FixTests.cjkProject(typed: "\\at{100}{500}{600}{.};")
        let output = tex.deletingLastPathComponent().appendingPathComponent("out.pdf")
        let result = try FormFiller.fill(tex: tex, output: output)
        #expect(result.passed, "\(result)")
    }
}
