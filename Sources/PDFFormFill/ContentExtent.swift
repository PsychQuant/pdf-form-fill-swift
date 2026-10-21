import CoreGraphics
import Foundation

/// Where a page draws, read from its content stream and the form XObjects
/// it uses, without rendering: the points of painted paths, the origin of
/// every shown string (following TJ displacements), and the corners of
/// images, in default user space. A render only shows what falls on the
/// page, so this is how drawing placed off it, at any distance, is found.
enum ContentExtent {

    /// Drawing positions outside the page's crop box (its edges count as
    /// inside), plus one for every form XObject that could not be scanned
    /// (a cycle, nesting deeper than 16 or more than 2000 forms in all):
    /// what cannot be checked never counts as on the page.
    static func positionsOutside(page: CGPDFPage) -> Int {
        let state = ScanState(box: page.getBoxRect(.cropBox))
        let stream = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(stream) }
        state.scan(stream, ctm: .identity, form: nil)
        return state.outside
    }
}

/// Graphics and text state while scanning; reached from the C callbacks
/// through the scanner's info pointer.
final class ScanState {
    static let maxDepth = 16
    static let maxForms = 2000

    let box: CGRect
    var outside = 0
    var ctm = CGAffineTransform.identity
    var saved: [CGAffineTransform] = []
    var textMatrix = CGAffineTransform.identity
    var lineMatrix = CGAffineTransform.identity
    var leading: CGFloat = 0
    var fontSize: CGFloat = 0
    var horizontalScale: CGFloat = 1
    /// Points of the path being built, marked only when it is painted.
    var pending: [CGPoint] = []
    /// Form XObjects on the current nesting path, to stop cycles.
    var path: [CGPDFStreamRef] = []
    var formsScanned = 0

    init(box: CGRect) {
        self.box = box
    }

    func mark(_ point: CGPoint) {
        let p = point.applying(ctm)
        let inside = p.x.isFinite && p.y.isFinite
            && p.x >= box.minX && p.x <= box.maxX && p.y >= box.minY && p.y <= box.maxY
        if !inside { outside += 1 }
    }

    func markTextOrigin() {
        mark(CGPoint.zero.applying(textMatrix))
    }

    func moveLine(_ tx: CGFloat, _ ty: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    /// A TJ number moves the next glyph left by number/1000 of the font size.
    func displace(_ amount: CGFloat) {
        textMatrix = CGAffineTransform(translationX: -amount / 1000 * fontSize * horizontalScale, y: 0)
            .concatenating(textMatrix)
    }

    func addPoint(_ x: CGFloat, _ y: CGFloat) {
        pending.append(CGPoint(x: x, y: y).applying(ctm))
    }

    func paint() {
        for p in pending {
            let inside = p.x.isFinite && p.y.isFinite
                && p.x >= box.minX && p.x <= box.maxX && p.y >= box.minY && p.y <= box.maxY
            if !inside { outside += 1 }
        }
        pending = []
    }

    /// Scans `stream` with the current transformation matrix set to `ctm`.
    /// `form` is the XObject being entered, if any.
    func scan(_ stream: CGPDFContentStreamRef, ctm start: CGAffineTransform, form: CGPDFStreamRef?) {
        if let form {
            guard path.count < Self.maxDepth, formsScanned < Self.maxForms, !path.contains(form) else {
                outside += 1
                return
            }
            formsScanned += 1
            path.append(form)
        }
        defer { if form != nil { path.removeLast() } }
        guard let table = Self.table else { return }
        let outer = (ctm, saved, textMatrix, lineMatrix, pending)
        ctm = start
        saved = []
        pending = []
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        (ctm, saved, textMatrix, lineMatrix, pending) = outer
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

    static func matrix(_ v: [CGFloat]) -> CGAffineTransform {
        CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    }

    static let table: CGPDFOperatorTableRef? = {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let s = ScanState.state(info) else { return }
            s.saved.append(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let s = ScanState.state(info), let ctm = s.saved.popLast() else { return }
            s.ctm = ctm
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 6) else { return }
            s.ctm = ScanState.matrix(v).concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            guard let s = ScanState.state(info) else { return }
            s.textMatrix = .identity
            s.lineMatrix = .identity
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 1) else { return }
            s.fontSize = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "Tz") { scanner, info in
            guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 1) else { return }
            s.horizontalScale = v[0] / 100
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 6) else { return }
            s.lineMatrix = ScanState.matrix(v)
            s.textMatrix = s.lineMatrix
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 2) else { return }
            s.moveLine(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 2) else { return }
            s.leading = -v[1]
            s.moveLine(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 1) else { return }
            s.leading = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            guard let s = ScanState.state(info) else { return }
            s.moveLine(0, -s.leading)
        }
        CGPDFOperatorTableSetCallback(table, "Tj") { _, info in
            ScanState.state(info)?.markTextOrigin()
        }
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else {
                s.markTextOrigin()
                return
            }
            for i in 0..<CGPDFArrayGetCount(array) {
                var number: CGPDFReal = 0
                if CGPDFArrayGetNumber(array, i, &number) {
                    s.displace(number)
                } else {
                    s.markTextOrigin()
                }
            }
        }
        for op in ["'", "\""] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                guard let s = ScanState.state(info) else { return }
                s.moveLine(0, -s.leading)
                s.markTextOrigin()
            }
        }
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 2) else { return }
            s.addPoint(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 2) else { return }
            s.addPoint(v[0], v[1])
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 6) else { return }
            for i in stride(from: 0, to: 6, by: 2) { s.addPoint(v[i], v[i + 1]) }
        }
        for op in ["v", "y"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 4) else { return }
                for i in stride(from: 0, to: 4, by: 2) { s.addPoint(v[i], v[i + 1]) }
            }
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 4) else { return }
            for (dx, dy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                s.addPoint(v[0] + dx * v[2], v[1] + dy * v[3])
            }
        }
        // Painting operators mark the path; `n` ends it unpainted (a clip).
        for op in ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                ScanState.state(info)?.paint()
            }
        }
        CGPDFOperatorTableSetCallback(table, "n") { _, info in
            ScanState.state(info)?.pending = []
        }
        // An inline image fills the unit square of the current matrix.
        CGPDFOperatorTableSetCallback(table, "EI") { _, info in
            guard let s = ScanState.state(info) else { return }
            for (x, y) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] { s.mark(CGPoint(x: x, y: y)) }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let s = ScanState.state(info) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name)
            else { return }
            var xobject: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &xobject), let xobject,
                  let dictionary = CGPDFStreamGetDictionary(xobject) else { return }
            var subtype: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(dictionary, "Subtype", &subtype)
            guard let subtype, String(cString: subtype) == "Form" else {
                // An image fills the unit square of the current matrix.
                for (x, y) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] { s.mark(CGPoint(x: x, y: y)) }
                return
            }
            var form = CGAffineTransform.identity
            var array: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                var v = [CGFloat](repeating: 0, count: 6)
                for i in 0..<6 {
                    var value: CGPDFReal = 0
                    CGPDFArrayGetNumber(array, i, &value)
                    v[i] = value
                }
                form = ScanState.matrix(v)
            }
            var resources: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            // A form without its own resources is still scanned; lookups in it simply find nothing.
            let stream = CGPDFContentStreamCreateWithStream(xobject, resources ?? dictionary,
                                                            CGPDFScannerGetContentStream(scanner))
            defer { CGPDFContentStreamRelease(stream) }
            s.scan(stream, ctm: form.concatenating(s.ctm), form: xobject)
        }
        return table
    }()
}
