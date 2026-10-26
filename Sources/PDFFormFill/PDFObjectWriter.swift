import CoreGraphics
import Foundation

/// Writes a new PDF from objects read through CGPDF without redrawing them.
/// Content streams keep their bytes (decoded, then deflated again), numbers
/// are written so they read back as the same values, and JPEG and JPEG 2000
/// data is kept as it is. A redraw through a CoreGraphics PDF context would
/// instead rewrite every coordinate, rounded, and change how the page renders.
struct PDFObjectWriter {
    struct Unsupported: Error {
        let reason: String
    }

    /// Bodies by object number − 1; nil until written.
    private var bodies: [Data?] = []
    private var dictionaries: [CGPDFDictionaryRef: Int] = [:]
    private var streams: [CGPDFStreamRef: Int] = [:]
    private var depth = 0
    static let maxDepth = 64

    /// Keys never copied: /Parent would pull in the source's page tree.
    static let skippedKeys: Set<String> = ["Parent"]

    mutating func reserve() -> Int {
        bodies.append(nil)
        return bodies.count
    }

    mutating func set(_ number: Int, _ body: Data) {
        bodies[number - 1] = body
    }

    /// A new stream object with `entries` (already serialized) and `data`.
    mutating func stream(entries: [(String, Data)], data: Data) -> Int {
        let number = reserve()
        set(number, Self.streamBody(entries: entries, data: data))
        return number
    }

    /// The serialized form of `object`; streams and dictionaries become
    /// references to indirect objects, written once each.
    mutating func value(_ object: CGPDFObjectRef) throws -> Data {
        switch CGPDFObjectGetType(object) {
        case .null:
            return Data("null".utf8)
        case .boolean:
            var value: CGPDFBoolean = 0
            CGPDFObjectGetValue(object, .boolean, &value)
            return Data((value != 0 ? "true" : "false").utf8)
        case .integer:
            var value: CGPDFInteger = 0
            CGPDFObjectGetValue(object, .integer, &value)
            return Data(String(value).utf8)
        case .real:
            var value: CGPDFReal = 0
            CGPDFObjectGetValue(object, .real, &value)
            return Data(try Self.number(value).utf8)
        case .name:
            var name: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &name), let name else { throw Unsupported(reason: "unreadable name") }
            return Data(Self.name(String(cString: name)).utf8)
        case .string:
            var string: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &string), let string else {
                throw Unsupported(reason: "unreadable string")
            }
            return Self.hexString(string)
        case .array:
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &array), let array else { throw Unsupported(reason: "unreadable array") }
            return try self.array(array)
        case .dictionary:
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else {
                throw Unsupported(reason: "unreadable dictionary")
            }
            return Self.reference(try self.dictionary(dictionary))
        case .stream:
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { throw Unsupported(reason: "unreadable stream") }
            return Self.reference(try self.stream(stream))
        @unknown default:
            throw Unsupported(reason: "unknown object type")
        }
    }

    mutating func array(_ array: CGPDFArrayRef) throws -> Data {
        try descend()
        defer { depth -= 1 }
        var out = Data("[".utf8)
        for i in 0..<CGPDFArrayGetCount(array) {
            var object: CGPDFObjectRef?
            guard CGPDFArrayGetObject(array, i, &object), let object else { throw Unsupported(reason: "unreadable array entry") }
            if i > 0 { out.append(Data(" ".utf8)) }
            out.append(try value(object))
        }
        out.append(Data("]".utf8))
        return out
    }

    /// The entries of `dictionary`, serialized, in key order.
    mutating func entries(of dictionary: CGPDFDictionaryRef, skipping: Set<String> = []) throws -> [(String, Data)] {
        var objects: [(String, CGPDFObjectRef)] = []
        CGPDFDictionaryApplyBlock(dictionary, { key, object, _ in
            objects.append((String(cString: key), object))
            return true
        }, nil)
        var out: [(String, Data)] = []
        for (key, object) in objects.sorted(by: { $0.0 < $1.0 })
        where !Self.skippedKeys.contains(key) && !skipping.contains(key) {
            out.append((key, try value(object)))
        }
        return out
    }

    /// The object number of a copy of `dictionary`.
    mutating func dictionary(_ dictionary: CGPDFDictionaryRef) throws -> Int {
        if let number = dictionaries[dictionary] { return number }
        let number = reserve()
        dictionaries[dictionary] = number
        try descend()
        defer { depth -= 1 }
        set(number, Self.dictionaryBody(try entries(of: dictionary)))
        return number
    }

    /// The object number of a copy of `stream`: its decoded data deflated
    /// again, or JPEG and JPEG 2000 data kept with their filter.
    mutating func stream(_ stream: CGPDFStreamRef) throws -> Int {
        if let number = streams[stream] { return number }
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { throw Unsupported(reason: "stream without dictionary") }
        var external: CGPDFObjectRef?
        guard !CGPDFDictionaryGetObject(dictionary, "F", &external) else { throw Unsupported(reason: "external stream") }
        let number = reserve()
        streams[stream] = number
        try descend()
        defer { depth -= 1 }
        var format = CGPDFDataFormat.raw
        guard let copied = CGPDFStreamCopyData(stream, &format) else { throw Unsupported(reason: "undecodable stream") }
        let decoded = copied as Data
        var entries = try self.entries(of: dictionary, skipping: ["Length", "Filter", "DecodeParms", "DL"])
        let data: Data
        switch format {
        case .raw:
            data = try Self.deflate(decoded)
            entries.append(("Filter", Data("/FlateDecode".utf8)))
        case .jpegEncoded:
            data = decoded
            entries.append(("Filter", Data("/DCTDecode".utf8)))
            if let parameters = try dctParameters(of: dictionary) { entries.append(("DecodeParms", parameters)) }
        case .JPEG2000:
            data = decoded
            entries.append(("Filter", Data("/JPXDecode".utf8)))
        @unknown default:
            throw Unsupported(reason: "unknown stream format")
        }
        set(number, Self.streamBody(entries: entries, data: data))
        return number
    }

    /// The /DecodeParms that belonged to a DCTDecode filter, if any.
    private mutating func dctParameters(of dictionary: CGPDFDictionaryRef) throws -> Data? {
        var filterName: UnsafePointer<CChar>?
        var filters: CGPDFArrayRef?
        var index: Int?
        if CGPDFDictionaryGetName(dictionary, "Filter", &filterName), let filterName {
            index = String(cString: filterName) == "DCTDecode" ? 0 : nil
        } else if CGPDFDictionaryGetArray(dictionary, "Filter", &filters), let filters {
            for i in 0..<CGPDFArrayGetCount(filters) {
                var name: UnsafePointer<CChar>?
                if CGPDFArrayGetName(filters, i, &name), let name, String(cString: name) == "DCTDecode" { index = i }
            }
        }
        guard let index else { return nil }
        var parameters: CGPDFDictionaryRef?
        var list: CGPDFArrayRef?
        if CGPDFDictionaryGetDictionary(dictionary, "DecodeParms", &parameters), let parameters, index == 0 {
            return Self.reference(try self.dictionary(parameters))
        }
        if CGPDFDictionaryGetArray(dictionary, "DecodeParms", &list), let list,
           CGPDFArrayGetDictionary(list, index, &parameters), let parameters {
            return Self.reference(try self.dictionary(parameters))
        }
        return nil
    }

    private mutating func descend() throws {
        depth += 1
        guard depth <= Self.maxDepth else {
            depth -= 1
            throw Unsupported(reason: "objects nested deeper than \(Self.maxDepth)")
        }
    }

    /// The finished file, with `root` as the catalog.
    func data(root: Int) throws -> Data {
        var out = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = []
        for (index, body) in bodies.enumerated() {
            guard let body else { throw Unsupported(reason: "object \(index + 1) was reserved but never written") }
            offsets.append(out.count)
            out.append(Data("\(index + 1) 0 obj\n".utf8))
            out.append(body)
            out.append(Data("\nendobj\n".utf8))
        }
        let xref = out.count
        var table = "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(bodies.count + 1) /Root \(root) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out.append(Data(table.utf8))
        return out
    }

    // MARK: Serialization

    static func reference(_ number: Int) -> Data {
        Data("\(number) 0 R".utf8)
    }

    static func dictionaryBody(_ entries: [(String, Data)]) -> Data {
        var out = Data("<<".utf8)
        for (key, value) in entries {
            out.append(Data(" \(name(key)) ".utf8))
            out.append(value)
        }
        out.append(Data(" >>".utf8))
        return out
    }

    static func streamBody(entries: [(String, Data)], data: Data) -> Data {
        var out = dictionaryBody(entries + [("Length", Data(String(data.count).utf8))])
        out.append(Data("\nstream\n".utf8))
        out.append(data)
        out.append(Data("\nendstream".utf8))
        return out
    }

    /// A number in plain decimal notation that reads back as the same value.
    static func number(_ value: CGFloat) throws -> String {
        guard value.isFinite else { throw Unsupported(reason: "non-finite number") }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.17f", Double(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    static func name(_ name: String) -> String {
        var out = "/"
        for byte in name.utf8 {
            let delimiter = "()<>[]{}/%#".utf8.contains(byte)
            if byte < 0x21 || byte > 0x7E || delimiter {
                out += String(format: "#%02X", byte)
            } else {
                out.append(Character(UnicodeScalar(byte)))
            }
        }
        return out
    }

    static func hexString(_ string: CGPDFStringRef) -> Data {
        var out = "<"
        if let bytes = CGPDFStringGetBytePtr(string) {
            for i in 0..<CGPDFStringGetLength(string) { out += String(format: "%02X", bytes[i]) }
        }
        return Data((out + ">").utf8)
    }

    /// zlib (RFC 1950) data for /FlateDecode: a header, raw deflate, and
    /// the Adler-32 checksum.
    static func deflate(_ data: Data) throws -> Data {
        guard let raw = try? (data as NSData).compressed(using: .zlib) as Data else {
            throw Unsupported(reason: "compression failed")
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let checksum = (b << 16) | a
        var out = Data([0x78, 0x9C])
        out.append(raw)
        out.append(contentsOf: [UInt8(checksum >> 24), UInt8((checksum >> 16) & 0xFF),
                                UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF)])
        return out
    }
}
