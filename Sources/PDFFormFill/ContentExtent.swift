import CoreGraphics
import Foundation

/// Where a page draws, read from its content stream and the form XObjects
/// it uses, without rendering: path points, text origins and image corners
/// in default user space. A render only shows what falls near the page, so
/// this is how drawing placed far away is found.
enum ContentExtent {

    /// Drawing positions more than one page width or height beyond the
    /// page's crop box. Content closer than that is left to a render.
    static func positionsFarOutside(page: CGPDFPage) -> Int {
        let box = page.getBoxRect(.cropBox)
        let state = ScanState(reach: box.insetBy(dx: -box.width, dy: -box.height))
        let stream = CGPDFContentStreamCreateWithPage(page)
        state.scan(stream, ctm: .identity)
        return state.outside
    }
}

/// Graphics and text state while scanning; reached from the C callbacks
/// through the scanner's info pointer.
final class ScanState {
    let reach: CGRect
    var outside = 0
    var ctm = CGAffineTransform.identity
    var saved: [CGAffineTransform] = []
    var textMatrix = CGAffineTransform.identity
    var lineMatrix = CGAffineTransform.identity
    var leading: CGFloat = 0
    var depth = 0

    init(reach: CGRect) {
        self.reach = reach
    }

    func mark(_ point: CGPoint, _ transform: CGAffineTransform) {
        let p = point.applying(transform)
        if !p.x.isFinite || !p.y.isFinite || !reach.contains(p) { outside += 1 }
    }

    func markTextOrigin() {
        mark(.zero, textMatrix.concatenating(ctm))
    }

    func moveLine(_ tx: CGFloat, _ ty: CGFloat) {
        lineMatrix = CGAffineTransform(translationX: tx, y: ty).concatenating(lineMatrix)
        textMatrix = lineMatrix
    }

    /// Scans `stream` with the current transformation matrix set to `ctm`.
    func scan(_ stream: CGPDFContentStreamRef, ctm start: CGAffineTransform) {
        guard depth < 16, let table = Self.table else { return }
        depth += 1
        defer { depth -= 1 }
        let outer = (ctm, saved, textMatrix, lineMatrix)
        ctm = start
        saved = []
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        (ctm, saved, textMatrix, lineMatrix) = outer
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
        for op in ["Tj", "TJ"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                ScanState.state(info)?.markTextOrigin()
            }
        }
        for op in ["'", "\""] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in
                guard let s = ScanState.state(info) else { return }
                s.moveLine(0, -s.leading)
                s.markTextOrigin()
            }
        }
        for (op, count) in [("m", 2), ("l", 2), ("c", 6), ("v", 4), ("y", 4)] {
            let callback: CGPDFOperatorCallback
            switch count {
            case 6:
                callback = { scanner, info in
                    guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 6) else { return }
                    for i in stride(from: 0, to: 6, by: 2) { s.mark(CGPoint(x: v[i], y: v[i + 1]), s.ctm) }
                }
            case 4:
                callback = { scanner, info in
                    guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 4) else { return }
                    for i in stride(from: 0, to: 4, by: 2) { s.mark(CGPoint(x: v[i], y: v[i + 1]), s.ctm) }
                }
            default:
                callback = { scanner, info in
                    guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 2) else { return }
                    s.mark(CGPoint(x: v[0], y: v[1]), s.ctm)
                }
            }
            CGPDFOperatorTableSetCallback(table, op, callback)
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let s = ScanState.state(info), let v = ScanState.numbers(scanner, 4) else { return }
            for (dx, dy) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                s.mark(CGPoint(x: v[0] + dx * v[2], y: v[1] + dy * v[3]), s.ctm)
            }
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
            if let subtype, String(cString: subtype) == "Form" {
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
                s.scan(stream, ctm: form.concatenating(s.ctm))
            } else {
                // An image fills the unit square of the current matrix.
                for (x, y) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] { s.mark(CGPoint(x: x, y: y), s.ctm) }
            }
        }
        return table
    }()
}
