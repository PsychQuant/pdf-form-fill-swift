import CoreGraphics
import CoreText
import Foundation
import PDFFormFill
import Testing

struct FormSkeletonTests {

    /// Word puts the labels of one form row on one text line separated by
    /// spaces; the expected glyph positions come from CoreText, not PDFKit.
    static let dateRow = "年      月      日"

    static func glyphOffsets(_ text: String, font: String, size: CGFloat) -> [CGFloat] {
        let ctFont = CTFontCreateWithName(font as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): ctFont]))
        var offsets: [CGFloat] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            var positions = [CGPoint](repeating: .zero, count: CTRunGetGlyphCount(run))
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            offsets += positions.map(\.x)
        }
        return offsets
    }

    static func blankForm() throws -> URL {
        try SyntheticPDF.make(size: SyntheticPDF.pdfMakerA4, [
            .text("填表日期", at: CGPoint(x: 300, y: 114.5), size: 10, font: "PingFang TC"),
            .text(dateRow, at: CGPoint(x: 207, y: 227.5), size: 12, font: "PingFang TC"),
            .line(from: CGPoint(x: 96, y: 120), to: CGPoint(x: 489, y: 120), width: 1),
        ])
    }

    @Test("labels are found at the positions they were drawn")
    func labelPositions() throws {
        let labels = try FormSkeleton.labels(in: Self.blankForm())
        let offsets = Self.glyphOffsets(Self.dateRow, font: "PingFang TC", size: 12)
        // Glyph indices of 年, 月, 日 in the row (spaces in between).
        let characters = Array(Self.dateRow)
        let expected: [(String, CGFloat, CGFloat)] = [
            ("填表日期", 300, 114.5),
            ("年", 207 + offsets[characters.firstIndex(of: "年")!], 227.5),
            ("月", 207 + offsets[characters.firstIndex(of: "月")!], 227.5),
            ("日", 207 + offsets[characters.firstIndex(of: "日")!], 227.5),
        ]
        #expect(labels.map(\.text) == expected.map(\.0))
        for (label, (text, x, baseline)) in zip(labels, expected) {
            #expect(abs(label.left - x) <= 0.5, "\(text) left \(label.left) vs \(x)")
            #expect(abs(label.baseline - baseline) <= 0.5, "\(text) baseline \(label.baseline) vs \(baseline)")
        }
    }

    @Test("the skeleton has one commented placement line per label")
    func commentedPlacementLines() throws {
        let skeleton = try FormSkeleton.generate(blankForm: Self.blankForm(), reference: "blank.pdf")
        let placements = skeleton.split(separator: "\n").filter { $0.hasPrefix("% \\at{") }
        #expect(placements.count == 4)
        let year = try #require(placements.first { $0.hasSuffix("% 年 (207.0, 227.5)") })
        #expect(year.contains("{227.5}"))
        #expect(skeleton.contains("\\newcommand{\\BlankForm}{blank.pdf}"))
        #expect(skeleton.contains("\\usepackage[a4paper,margin=0pt]{geometry}"))
        #expect(skeleton.contains("\\newcommand{\\at}[3]"))
    }

    @Test("the same form always gives the same skeleton")
    func deterministic() throws {
        let form = try Self.blankForm()
        #expect(try FormSkeleton.generate(blankForm: form, reference: "blank.pdf")
                == FormSkeleton.generate(blankForm: form, reference: "blank.pdf"))
    }

    @Test("a form without text still gives a usable skeleton")
    func noText() throws {
        let form = try SyntheticPDF.make(size: SyntheticPDF.a4, [.line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 10), width: 1)])
        let skeleton = try FormSkeleton.generate(blankForm: form, reference: "blank.pdf")
        #expect(skeleton.contains("\\begin{tikzpicture}"))
        #expect(!skeleton.contains("% \\at{"))
    }

    @Test("an unreadable form is reported with its path")
    func unreadable() {
        let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).pdf")
        #expect(throws: FormFillError.unreadablePDF(url.path)) {
            try FormSkeleton.labels(in: url)
        }
    }
}
