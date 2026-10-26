import CoreGraphics
import Foundation

/// Where an overlay page draws, read from its content stream and the form
/// XObjects it uses, without rendering. A render only shows what falls near
/// the page, so this is how drawing placed far off it is found.
///
/// The work is split with the pixel check (`PageGeometry.inkOutsideCropBox`),
/// which sees ink up to one page beyond each edge. This scan marks the
/// points of painted paths, the corners of images and shadings, and a box
/// around every glyph it can place (the font's /FontBBox, or an em-based box
/// when the font gives none), and reports those more than 0.9 of a page
/// beyond the crop box. For paths, images and fonts whose /FontBBox is true
/// to their glyphs, ink lies within the marks, so whatever the scan does not
/// report lies where the pixel check sees it. Drawing whose clip lies within
/// that reach cannot be visible beyond it and is not reported.
enum ContentExtent {

    struct Result: Equatable {
        /// Marked positions more than 0.9 of a page beyond the crop box.
        var outside = 0
        /// Parts that could not be placed: text in a font without width
        /// data, a form XObject that cannot be read to the end (a cycle,
        /// nesting deeper than 16, more than 2000 distinct forms or 100000
        /// form invocations), an unresolvable resource, an operator whose
        /// operands cannot be read, or a content stream that fails to parse.
        var undecidable = 0
    }

    static func scan(page: CGPDFPage) -> Result {
        let box = page.getBoxRect(.cropBox)
        let state = ScanState(reach: box.insetBy(dx: -box.width * 0.9, dy: -box.height * 0.9))
        state.resources = inheritedResources(of: page)
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        state.scan(stream, form: nil)
        return state.result
    }

    /// The page's /Resources, inherited through /Parent when the page has none.
    static func inheritedResources(of page: CGPDFPage) -> CGPDFDictionaryRef? {
        var node = page.dictionary
        for _ in 0..<64 {
            guard let current = node else { return nil }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources { return resources }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
        }
        return nil
    }
}

/// Glyph widths of one font, enough to follow the pen across a string.
final class FontMetrics {
    /// Two bytes per character code (Identity-H or Identity-V).
    let twoByte: Bool
    let vertical: Bool
    /// Glyph width per code (simple fonts) or CID, in text space per unit of
    /// font size; vertical fonts hold the vertical advance w1y instead.
    private var widths: [Int: CGFloat] = [:]
    private var ranges: [(ClosedRange<Int>, CGFloat)] = []
    private let missing: CGFloat
    /// The font's bounding box (/FontBBox), which holds the ink of every
    /// glyph, in text space per unit of font size; nil when the font gives
    /// none or a degenerate one.
    var bbox: CGRect?

    private init(twoByte: Bool, vertical: Bool, missing: CGFloat) {
        self.twoByte = twoByte
        self.vertical = vertical
        self.missing = missing
    }

    func advance(of code: Int) -> CGFloat {
        if let width = widths[code] { return width }
        var low = 0, high = ranges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let (range, width) = ranges[mid]
            if code < range.lowerBound { high = mid - 1 } else if code > range.upperBound { low = mid + 1 } else { return width }
        }
        return missing
    }

    /// Reads /Widths (simple fonts) or the descendant's /W, /DW, /W2, /DW2
    /// (Identity-H and Identity-V Type0 fonts). Any other font returns nil:
    /// its characters cannot be placed.
    static func load(_ font: CGPDFDictionaryRef) -> FontMetrics? {
        guard let subtype = name(font, "Subtype") else { return nil }
        if subtype == "Type0" {
            guard let encoding = name(font, "Encoding"), encoding == "Identity-H" || encoding == "Identity-V" else { return nil }
            var descendants: CGPDFArrayRef?
            var descendant: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
                  CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant else { return nil }
            let vertical = encoding == "Identity-V"
            if vertical {
                var dw2: CGPDFArrayRef?
                var w1: CGPDFReal = -1000
                if CGPDFDictionaryGetArray(descendant, "DW2", &dw2), let dw2 { CGPDFArrayGetNumber(dw2, 1, &w1) }
                let metrics = FontMetrics(twoByte: true, vertical: true, missing: w1 / 1000)
                var w2: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(descendant, "W2", &w2), let w2 { metrics.readCIDArray(w2, stride: 3) }
                metrics.bbox = descriptorBBox(descendant, sx: 0.001, sy: 0.001)
                return metrics
            }
            var dw: CGPDFReal = 1000
            CGPDFDictionaryGetNumber(descendant, "DW", &dw)
            let metrics = FontMetrics(twoByte: true, vertical: false, missing: dw / 1000)
            var w: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(descendant, "W", &w), let w { metrics.readCIDArray(w, stride: 1) }
            metrics.bbox = descriptorBBox(descendant, sx: 0.001, sy: 0.001)
            return metrics
        }
        // A Type3 glyph is a content stream that may draw anywhere, whatever
        // its /FontBBox says, so its characters cannot be placed.
        guard ["Type1", "MMType1", "TrueType"].contains(subtype) else { return nil }
        var widthArray: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(font, "Widths", &widthArray), let widthArray else { return nil }
        let scale: CGFloat = 0.001
        var first: CGPDFInteger = 0
        CGPDFDictionaryGetInteger(font, "FirstChar", &first)
        var missingWidth: CGPDFReal = 0
        var descriptor: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor), let descriptor {
            CGPDFDictionaryGetNumber(descriptor, "MissingWidth", &missingWidth)
        }
        let metrics = FontMetrics(twoByte: false, vertical: false, missing: missingWidth * scale)
        for i in 0..<CGPDFArrayGetCount(widthArray) {
            var width: CGPDFReal = 0
            // Simple fonts have one-byte codes; entries past 255 never apply.
            guard first >= 0, first <= 255 - i else { break }
            if CGPDFArrayGetNumber(widthArray, i, &width) { metrics.widths[first + i] = width * scale }
        }
        metrics.bbox = descriptorBBox(font, sx: scale, sy: scale)
        return metrics
    }

    private static func descriptorBBox(_ font: CGPDFDictionaryRef, sx: CGFloat, sy: CGFloat) -> CGRect? {
        var descriptor: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor), let descriptor else { return nil }
        return rect(descriptor, "FontBBox", sx: sx, sy: sy)
    }

    /// A four-number rectangle scaled to text space; nil unless every number
    /// reads, is finite, and the rectangle has area.
    private static func rect(_ dictionary: CGPDFDictionaryRef, _ key: String, sx: CGFloat, sy: CGFloat) -> CGRect? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array, CGPDFArrayGetCount(array) == 4 else { return nil }
        var v = [CGFloat](repeating: 0, count: 4)
        for i in 0..<4 {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, i, &value) else { return nil }
            v[i] = value
        }
        let x = [v[0] * sx, v[2] * sx], y = [v[1] * sy, v[3] * sy]
        let box = CGRect(x: x.min()!, y: y.min()!, width: abs(x[1] - x[0]), height: abs(y[1] - y[0]))
        guard [box.minX, box.minY, box.maxX, box.maxY].allSatisfy(\.isFinite), box.width > 0, box.height > 0 else {
            return nil
        }
        return box
    }

    /// /W (stride 1: one width per CID) or /W2 (stride 3: w1y, vx, vy per
    /// CID), in either form: `c [values]` or `cfirst clast values`.
    private func readCIDArray(_ array: CGPDFArrayRef, stride: Int) {
        let count = CGPDFArrayGetCount(array)
        var i = 0
        while i < count {
            var first: CGPDFInteger = 0
            guard CGPDFArrayGetInteger(array, i, &first) else { return }
            var list: CGPDFArrayRef?
            if CGPDFArrayGetArray(array, i + 1, &list), let list {
                let n = CGPDFArrayGetCount(list) / stride
                // CIDs are two bytes; entries past 0xFFFF never apply.
                for k in 0..<n {
                    guard first >= 0, first <= 0xFFFF - k else { break }
                    var value: CGPDFReal = 0
                    if CGPDFArrayGetNumber(list, k * stride, &value) { widths[first + k] = value / 1000 }
                }
                i += 2
            } else {
                var last: CGPDFInteger = 0
                var value: CGPDFReal = 0
                guard CGPDFArrayGetInteger(array, i + 1, &last), CGPDFArrayGetNumber(array, i + 2, &value),
                      last >= first else { return }
                ranges.append((first...last, value / 1000))
                i += 2 + stride
            }
        }
        ranges.sort { $0.0.lowerBound < $1.0.lowerBound }
    }

    private static func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, key, &value), let value else { return nil }
        return String(cString: value)
    }
}

/// The parts of the graphics state the scan follows; `q`, `Q` and form
/// XObjects save and restore all of it.
struct ScanGState {
    var ctm = CGAffineTransform.identity
    /// Bounding box of the clip in default user space.
    var clip = CGRect.infinite
    var font: FontMetrics?
    var fontSize: CGFloat = 0
    var charSpacing: CGFloat = 0
    var wordSpacing: CGFloat = 0
    var horizontalScale: CGFloat = 1
    var leading: CGFloat = 0
    var renderMode = 0
    var rise: CGFloat = 0
}

/// State while scanning; reached from the C callbacks through the
/// scanner's info pointer.
final class ScanState {
    static let maxDepth = 16
    static let maxForms = 2000
    static let maxInvocations = 100_000

    let reach: CGRect
    var result = ContentExtent.Result()
    var g = ScanGState()
    var saved: [ScanGState] = []
    var textMatrix = CGAffineTransform.identity
    var lineMatrix = CGAffineTransform.identity
    /// Points of the path being built, in default user space.
    var pending: [CGPoint] = []
    var clipPending = false
    /// Form XObjects on the current nesting path, to stop cycles.
    var path: [CGPDFStreamRef] = []
    var forms = Set<CGPDFStreamRef>()
    var invocations = 0
    var fonts: [CGPDFDictionaryRef: FontMetrics?] = [:]
    /// The resources in effect: a form without its own uses its caller's,
    /// as a renderer does.
    var resources: CGPDFDictionaryRef?

    init(reach: CGRect) {
        self.reach = reach
    }

    /// Nothing drawn under a clip that lies within reach can show beyond it.
    var clippedWithinReach: Bool {
        let clip = g.clip
        if clip.isNull { return true }
        guard !clip.isInfinite, clip.minX.isFinite, clip.minY.isFinite, clip.maxX.isFinite, clip.maxY.isFinite else {
            return false
        }
        return reach.contains(clip)
    }

    /// Marks a point given in default user space.
    func markDevice(_ p: CGPoint) {
        if clippedWithinReach { return }
        let inside = p.x.isFinite && p.y.isFinite && reach.contains(p)
        if !inside { result.outside += 1 }
    }

    func mark(_ point: CGPoint) {
        markDevice(point.applying(g.ctm))
    }

    func moveLine(_ tx: CGFloat, _ ty: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    /// Marks a box around the glyph at the pen, raised by Ts.
    func markGlyph(_ font: FontMetrics) {
        guard g.renderMode != 3, g.renderMode != 7 else { return }
        let size = g.fontSize
        let rendering = CGAffineTransform(a: size * g.horizontalScale, b: 0, c: 0, d: size, tx: 0, ty: g.rise)
            .concatenating(textMatrix).concatenating(g.ctm)
        // The font's own bounding box when it gives one (horizontal writing);
        // otherwise a box from one em before the pen to two after it.
        let box = font.vertical ? nil : font.bbox
        let corners: [(CGFloat, CGFloat)] = box.map {
            [($0.minX, $0.minY), ($0.maxX, $0.minY), ($0.minX, $0.maxY), ($0.maxX, $0.maxY)]
        } ?? [(-1, -1), (2, -1), (-1, 1), (2, 1)]
        for (x, y) in corners {
            markDevice(CGPoint(x: x, y: y).applying(rendering))
        }
    }

    /// Shows a string: each glyph is marked, then the pen advances by the
    /// glyph's width with Tc, Tw and Tz (or vertically for Identity-V).
    func show(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let font = g.font else {
            // Text that cannot be placed is harmless under a clip within reach.
            if !bytes.isEmpty && !clippedWithinReach { result.undecidable += 1 }
            return
        }
        var i = 0
        while i < bytes.count {
            let code: Int
            if font.twoByte {
                code = Int(bytes[i]) << 8 | (i + 1 < bytes.count ? Int(bytes[i + 1]) : 0)
                i += 2
            } else {
                code = Int(bytes[i])
                i += 1
            }
            markGlyph(font)
            let spacing = g.charSpacing + (!font.twoByte && code == 32 ? g.wordSpacing : 0)
            let width = font.advance(of: code) * g.fontSize
            let move = font.vertical
                ? CGAffineTransform(translationX: 0, y: width + spacing)
                : CGAffineTransform(translationX: (width + spacing) * g.horizontalScale, y: 0)
            textMatrix = move.concatenating(textMatrix)
        }
    }

    /// A TJ number moves the pen back by number/1000 of the font size.
    func displace(_ amount: CGFloat) {
        let move = -amount / 1000 * g.fontSize
        let shift = g.font?.vertical == true
            ? CGAffineTransform(translationX: 0, y: move)
            : CGAffineTransform(translationX: move * g.horizontalScale, y: 0)
        textMatrix = shift.concatenating(textMatrix)
    }

    func addPoint(_ x: CGFloat, _ y: CGFloat) {
        pending.append(CGPoint(x: x, y: y).applying(g.ctm))
    }

    /// Ends the path: `paint` marks its points first; a pending `W` then
    /// narrows the clip to the path's bounding box.
    func endPath(paint: Bool) {
        if paint { pending.forEach(markDevice) }
        if clipPending {
            if pending.isEmpty || pending.contains(where: { !$0.x.isFinite || !$0.y.isFinite }) {
                // A clip with no path is ignored by renderers, and one that
                // cannot be bounded leaves the clip as it was.
            } else if let first = pending.first {
                var low = first, high = first
                for p in pending {
                    low = CGPoint(x: min(low.x, p.x), y: min(low.y, p.y))
                    high = CGPoint(x: max(high.x, p.x), y: max(high.y, p.y))
                }
                g.clip = g.clip.intersection(CGRect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y))
            }
            clipPending = false
        }
        pending = []
    }

    func font(_ dictionary: CGPDFDictionaryRef) -> FontMetrics? {
        if let cached = fonts[dictionary] { return cached }
        let metrics = FontMetrics.load(dictionary)
        fonts[dictionary] = metrics
        return metrics
    }

    /// Scans `stream`; `form` is the XObject being entered, if any, whose
    /// graphics state the caller has already set up.
    func scan(_ stream: CGPDFContentStreamRef, form: CGPDFStreamRef?) {
        if let form {
            invocations += 1
            forms.insert(form)
            guard path.count < Self.maxDepth, forms.count <= Self.maxForms, invocations <= Self.maxInvocations,
                  !path.contains(form) else {
                result.undecidable += 1
                return
            }
            path.append(form)
        }
        defer { if form != nil { path.removeLast() } }
        guard let table = Self.table else {
            result.undecidable += 1
            return
        }
        let outer = (saved, textMatrix, lineMatrix, pending, clipPending)
        saved = []
        pending = []
        clipPending = false
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        if !CGPDFScannerScan(scanner) { result.undecidable += 1 }
        CGPDFScannerRelease(scanner)
        (saved, textMatrix, lineMatrix, pending, clipPending) = outer
    }

    static func state(_ info: UnsafeMutableRawPointer?) -> ScanState? {
        info.map { Unmanaged<ScanState>.fromOpaque($0).takeUnretainedValue() }
    }

    /// The last `count` numbers on the operand stack, in operand order.
    static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
        var values: [CGFloat] = []
        for _ in 0..<count {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
            values.append(value)
        }
        return values.reversed()
    }

    /// Exactly `count` numbers from an array, or nil.
    static func numbers(in array: CGPDFArrayRef, count: Int) -> [CGFloat]? {
        guard CGPDFArrayGetCount(array) == count else { return nil }
        var values: [CGFloat] = []
        for i in 0..<count {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, i, &value) else { return nil }
            values.append(value)
        }
        return values
    }

    static func matrix(_ v: [CGFloat]) -> CGAffineTransform {
        CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    }

    static func string(_ scanner: CGPDFScannerRef, into s: ScanState) {
        var string: CGPDFStringRef?
        guard CGPDFScannerPopString(scanner, &string), let string else {
            s.result.undecidable += 1
            return
        }
        s.show(bytes(of: string))
    }

    static func bytes(of string: CGPDFStringRef) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: CGPDFStringGetBytePtr(string), count: CGPDFStringGetLength(string))
    }

    static func unitSquare(_ s: ScanState) {
        for (x, y) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] { s.mark(CGPoint(x: x, y: y)) }
    }

    static let table: CGPDFOperatorTableRef? = {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let s = ScanState.state(info) else { return }
            s.saved.append(s.g)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let s = ScanState.state(info), let g = s.saved.popLast() else { return }
            s.g = g
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 6) else { s.result.undecidable += 1; return }
            s.g.ctm = ScanState.matrix(v).concatenating(s.g.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            guard let s = ScanState.state(info) else { return }
            s.textMatrix = .identity
            s.lineMatrix = .identity
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 1) else { s.result.undecidable += 1; return }
            s.g.fontSize = v[0]
            var name: UnsafePointer<CChar>?
            var dictionary: CGPDFDictionaryRef?
            if CGPDFScannerPopName(scanner, &name), let name,
               let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Font", name),
               CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary {
                s.g.font = s.font(dictionary)
            } else {
                // Text shown in an unresolved font counts when it is shown.
                s.g.font = nil
            }
        }
        // An ExtGState can set the font and size with /Font [font size].
        CGPDFOperatorTableSetCallback(table, "gs") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            var name: UnsafePointer<CChar>?
            var state: CGPDFDictionaryRef?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "ExtGState", name),
                  CGPDFObjectGetValue(object, .dictionary, &state), let state else {
                s.result.undecidable += 1
                return
            }
            var font: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(state, "Font", &font), let font else { return }
            var dictionary: CGPDFDictionaryRef?
            var size: CGPDFReal = 0
            guard CGPDFArrayGetDictionary(font, 0, &dictionary), let dictionary, CGPDFArrayGetNumber(font, 1, &size) else {
                s.g.font = nil
                s.result.undecidable += 1
                return
            }
            s.g.font = s.font(dictionary)
            s.g.fontSize = size
        }
        CGPDFOperatorTableSetCallback(table, "Tc") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 1) else { s.result.undecidable += 1; return }
            s.g.charSpacing = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "Tw") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 1) else { s.result.undecidable += 1; return }
            s.g.wordSpacing = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 1) else { s.result.undecidable += 1; return }
            s.g.horizontalScale = v[0] / 100
        }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 1) else { s.result.undecidable += 1; return }
            s.g.leading = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "Ts") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 1) else { s.result.undecidable += 1; return }
            s.g.rise = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode) { s.g.renderMode = mode } else { s.result.undecidable += 1 }
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 6) else { s.result.undecidable += 1; return }
            s.lineMatrix = ScanState.matrix(v)
            s.textMatrix = s.lineMatrix
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 2) else { s.result.undecidable += 1; return }
            s.moveLine(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 2) else { s.result.undecidable += 1; return }
            s.g.leading = -v[1]
            s.moveLine(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            guard let s = ScanState.state(info) else { return }
            s.moveLine(0, -s.g.leading)
        }
        CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            ScanState.string(scanner, into: s)
        }
        CGPDFOperatorTableSetCallback(table, "'") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            s.moveLine(0, -s.g.leading)
            ScanState.string(scanner, into: s)
        }
        CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            var string: CGPDFStringRef?
            guard CGPDFScannerPopString(scanner, &string), let string,
                  let v = ScanState.numbers(scanner, 2) else {
                s.result.undecidable += 1
                return
            }
            s.g.wordSpacing = v[0]
            s.g.charSpacing = v[1]
            s.moveLine(0, -s.g.leading)
            s.show(ScanState.bytes(of: string))
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else {
                s.result.undecidable += 1
                return
            }
            for i in 0..<CGPDFArrayGetCount(array) {
                var number: CGPDFReal = 0
                var string: CGPDFStringRef?
                if CGPDFArrayGetNumber(array, i, &number) {
                    s.displace(number)
                } else if CGPDFArrayGetString(array, i, &string), let string {
                    s.show(ScanState.bytes(of: string))
                } else {
                    s.result.undecidable += 1
                }
            }
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 2) else { s.result.undecidable += 1; return }
            s.addPoint(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 2) else { s.result.undecidable += 1; return }
            s.addPoint(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 6) else { s.result.undecidable += 1; return }
            for i in Swift.stride(from: 0, to: 6, by: 2) { s.addPoint(v[i], v[i + 1]) }
        }
        for op in ["v", "y"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 4) else { s.result.undecidable += 1; return }
                for i in Swift.stride(from: 0, to: 4, by: 2) { s.addPoint(v[i], v[i + 1]) }
            }
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            guard let v = ScanState.numbers(scanner, 4) else { s.result.undecidable += 1; return }
            for (dx, dy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                s.addPoint(v[0] + dx * v[2], v[1] + dy * v[3])
            }
        }
        for op in ["W", "W*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                ScanState.state(info)?.clipPending = true
            }
        }
        // Painting operators mark the path; `n` ends it unpainted (a clip).
        for op in ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                ScanState.state(info)?.endPath(paint: true)
            }
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in
            ScanState.state(info)?.endPath(paint: false)
        }
        // A shading fills the whole clip.
        // A shading fills the clip, limited by its own /BBox when it has one.
        CGPDFOperatorTableSetCallback(table, "sh") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            var name: UnsafePointer<CChar>?
            var shading: CGPDFDictionaryRef?
            var shadingStream: CGPDFStreamRef?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "Shading", name) else {
                s.result.undecidable += 1
                return
            }
            if CGPDFObjectGetValue(object, .dictionary, &shading) {
            } else if CGPDFObjectGetValue(object, .stream, &shadingStream), let shadingStream {
                shading = CGPDFStreamGetDictionary(shadingStream)
            }
            guard let shading else {
                s.result.undecidable += 1
                return
            }
            if s.clippedWithinReach { return }
            var bbox: CGPDFArrayRef?
            var v = [CGFloat](repeating: 0, count: 4)
            guard CGPDFDictionaryGetArray(shading, "BBox", &bbox), let bbox, CGPDFArrayGetCount(bbox) == 4,
                  (0..<4).allSatisfy({ i in
                      var value: CGPDFReal = 0
                      guard CGPDFArrayGetNumber(bbox, i, &value) else { return false }
                      v[i] = value
                      return true
                  }) else {
                // Unbounded by its clip or itself: where it paints is unknown.
                s.result.undecidable += 1
                return
            }
            for (x, y) in [(v[0], v[1]), (v[2], v[1]), (v[0], v[3]), (v[2], v[3])] { s.mark(CGPoint(x: x, y: y)) }
        }
        // An inline image fills the unit square of the current matrix.
        CGPDFOperatorTableSetCallback(table, "EI") { _, info in
            guard let s = ScanState.state(info) else { return }
            ScanState.unitSquare(s)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            // An XObject that cannot be resolved cannot be placed.
            var name: UnsafePointer<CChar>?
            var xobject: CGPDFStreamRef?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name),
                  CGPDFObjectGetValue(object, .stream, &xobject), let xobject,
                  let dictionary = CGPDFStreamGetDictionary(xobject) else {
                s.result.undecidable += 1
                return
            }
            var subtype: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(dictionary, "Subtype", &subtype)
            guard let subtype, String(cString: subtype) == "Form" else {
                // An image fills the unit square of the current matrix.
                ScanState.unitSquare(s)
                return
            }
            var form = CGAffineTransform.identity
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array {
                guard let v = ScanState.numbers(in: array, count: 6) else {
                    s.result.undecidable += 1
                    return
                }
                form = ScanState.matrix(v)
            }
            let outer = s.g
            s.g.ctm = form.concatenating(s.g.ctm)
            // The form's /BBox clips its content.
            var bbox: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "BBox", &bbox), let bbox {
                guard let v = ScanState.numbers(in: bbox, count: 4) else {
                    s.g = outer
                    s.result.undecidable += 1
                    return
                }
                let rect = CGRect(x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
                s.g.clip = s.g.clip.intersection(rect.applying(s.g.ctm))
            }
            var own: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &own)
            let callerResources = s.resources
            s.resources = own ?? callerResources
            let stream = CGPDFContentStreamCreateWithStream(xobject, s.resources ?? dictionary,
                                                            CGPDFScannerGetContentStream(scanner))
            defer { CGPDFContentStreamRelease(stream) }
            s.scan(stream, form: xobject)
            s.g = outer
            s.resources = callerResources
        }
        return table
    }()
}
