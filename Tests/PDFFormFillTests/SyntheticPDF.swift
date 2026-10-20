import CoreGraphics
import CoreText
import Foundation

/// Builds small PDFs for tests with CoreGraphics, so no real form ever has to
/// live in this repository. All coordinates are in bp with a top-left origin,
/// matching how the library reports positions.
enum SyntheticPDF {
    enum Item {
        /// A stroked line from `from` to `to`.
        case line(from: CGPoint, to: CGPoint, width: CGFloat)
        /// Text whose baseline starts at `at` (left end of the baseline).
        case text(String, at: CGPoint, size: CGFloat, font: String)
        /// A solid black rectangle.
        case fill(CGRect)
    }

    struct Page {
        var size: CGSize
        var items: [Item]
    }

    static let a4 = CGSize(width: 210 / 25.4 * 72, height: 297 / 25.4 * 72)
    /// A near-A4 page (within 1.5 bp of A4), larger than A4 in both dimensions.
    static let nearA4 = CGSize(width: 596, height: 843)

    static func write(_ pages: [Page], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for page in pages {
            var box = CGRect(origin: .zero, size: page.size)
            context.beginPage(mediaBox: &box)
            for item in page.items {
                draw(item, in: context, pageHeight: page.size.height)
            }
            context.endPage()
        }
        context.closePDF()
    }

    static func make(_ pages: [Page], name: String = UUID().uuidString) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-form-fill-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name).appendingPathExtension("pdf")
        try write(pages, to: url)
        return url
    }

    static func make(size: CGSize, _ items: [Item]) throws -> URL {
        try make([Page(size: size, items: items)])
    }

    private static func draw(_ item: Item, in context: CGContext, pageHeight h: CGFloat) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        switch item {
        case let .line(from, to, width):
            context.setLineWidth(width)
            context.move(to: CGPoint(x: from.x, y: h - from.y))
            context.addLine(to: CGPoint(x: to.x, y: h - to.y))
            context.strokePath()
        case let .fill(rect):
            context.fill(CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height))
        case let .text(string, at, size, fontName):
            let font = CTFontCreateWithName(fontName as CFString, size, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            context.textPosition = CGPoint(x: at.x, y: h - at.y)
            CTLineDraw(line, context)
        }
    }
}
