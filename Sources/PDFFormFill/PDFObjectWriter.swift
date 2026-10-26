import CoreGraphics
import Foundation

/// Writes a new PDF from objects read through CGPDF without redrawing them.
/// Content streams keep their bytes (decoded, then deflated again), numbers
/// are written so they read back as the same values, and JPEG and JPEG 2000
/// data is kept as it is. A redraw through a CoreGraphics PDF context would
/// instead rewrite every coordinate, rounded, and change how the page renders.
struct PDFObjectWriter {
    /// Bodies by object number − 1; nil until written.
    private var bodies: [Data?] = []
    private var dictionaries: [CGPDFDictionaryRef: Int] = [:]
    private var streams: [CGPDFStreamRef: Int] = [:]
    /// Arrays written once inline; a second use makes them indirect, so a
    /// shared array is never expanded again (2^depth copies otherwise).
    private var arrays: [CGPDFArrayRef: (data: Data, number: Int?)] = [:]
    /// Strings likewise: a long string referred to from many keys is
    /// written once as an indirect object.
    private var strings: [CGPDFStringRef: (data: Data, number: Int?)] = [:]
    private var depth = 0
    private var written = 0
    /// The byte budget for this copy (`maxBytes` unless a test lowers it).
    let budget: Int

    init(budget: Int = PDFObjectWriter.maxBytes) {
        self.budget = budget
    }
    static let maxDepth = 64
    /// Total bytes the copy may write: far beyond any form, and a stop for
    /// files built to expand.
    static let maxBytes = 256 << 20

    /// Keys never copied: /Parent would pull in the source's page tree.
    static let skippedKeys: Set<String> = ["Parent"]

    mutating func reserve() -> Int {
        bodies.append(nil)
        return bodies.count
    }

    /// Every body goes through here, so the budget bounds the whole copy.
    mutating func set(_ number: Int, _ body: Data) throws {
        try checkBudget(adding: body.count)
        bodies[number - 1] = body
        written += body.count
    }

    private func checkBudget(adding count: Int = 0) throws {
        guard written + count <= budget else {
            throw StampRefusal.tooLarge(limit: budget)
        }
    }

    /// A new stream object with `entries` (already serialized) and `data`.
    mutating func stream(entries: [(String, Data)], data: Data) throws -> Int {
        let number = reserve()
        try set(number, Self.streamBody(entries: entries, data: data))
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
            guard CGPDFObjectGetValue(object, .name, &name), let name else { throw StampRefusal.unreadable(.name) }
            return Self.name(bytes: Self.bytes(name))
        case .string:
            var string: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &string), let string else {
                throw StampRefusal.unreadable(.string)
            }
            if let cached = strings[string] {
                if let number = cached.number { return Self.reference(number) }
                let number = reserve()
                try set(number, cached.data)
                strings[string] = (cached.data, number)
                return Self.reference(number)
            }
            let data = Self.hexString(string)
            try checkBudget(adding: data.count)
            strings[string] = (data, nil)
            return data
        case .array:
            var array: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &array), let array else { throw StampRefusal.unreadable(.array) }
            return try self.array(array)
        case .dictionary:
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else {
                throw StampRefusal.unreadable(.dictionary)
            }
            return Self.reference(try self.dictionary(dictionary))
        case .stream:
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { throw StampRefusal.unreadable(.stream) }
            return Self.reference(try self.stream(stream))
        @unknown default:
            throw StampRefusal.unreadable(.unknown)
        }
    }

    mutating func array(_ array: CGPDFArrayRef) throws -> Data {
        if let cached = arrays[array] {
            if let number = cached.number { return Self.reference(number) }
            let number = reserve()
            try set(number, cached.data)
            arrays[array] = (cached.data, number)
            return Self.reference(number)
        }
        let data = try inlineArray(array)
        arrays[array] = (data, nil)
        return data
    }

    private mutating func inlineArray(_ array: CGPDFArrayRef) throws -> Data {
        try descend()
        defer { depth -= 1 }
        var out = Data("[".utf8)
        for i in 0..<CGPDFArrayGetCount(array) {
            var object: CGPDFObjectRef?
            guard CGPDFArrayGetObject(array, i, &object), let object else { throw StampRefusal.unreadable(.arrayEntry) }
            if i > 0 { out.append(Data(" ".utf8)) }
            out.append(try value(object))
            try checkBudget(adding: out.count)
        }
        out.append(Data("]".utf8))
        return out
    }

    /// The entries of `dictionary`, serialized, in key order. Keys keep
    /// their bytes; the String is for comparison only.
    mutating func entries(of dictionary: CGPDFDictionaryRef, skipping: Set<String> = []) throws -> [(String, Data)] {
        var objects: [([UInt8], CGPDFObjectRef)] = []
        CGPDFDictionaryApplyBlock(dictionary, { key, object, _ in
            objects.append((Self.bytes(key), object))
            return true
        }, nil)
        var out: [(String, Data)] = []
        var size = 0
        for (key, object) in objects.sorted(by: { $0.0.lexicographicallyPrecedes($1.0) }) {
            let text = String(decoding: key, as: UTF8.self)
            guard !Self.skippedKeys.contains(text), !skipping.contains(text) else { continue }
            let value = try value(object)
            size += key.count + value.count
            try checkBudget(adding: size)
            out.append((Self.nameKey(key), value))
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
        try set(number, Self.dictionaryBody(try entries(of: dictionary)))
        return number
    }

    /// The object number of a copy of `stream`: its decoded data deflated
    /// again, or JPEG and JPEG 2000 data kept with their filter.
    mutating func stream(_ stream: CGPDFStreamRef) throws -> Int {
        if let number = streams[stream] { return number }
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { throw StampRefusal.streamWithoutDictionary }
        var external: CGPDFObjectRef?
        guard !CGPDFDictionaryGetObject(dictionary, "F", &external) else { throw StampRefusal.externalStream }
        let number = reserve()
        streams[stream] = number
        try descend()
        defer { depth -= 1 }
        var format = CGPDFDataFormat.raw
        guard let copied = CGPDFStreamCopyData(stream, &format) else { throw StampRefusal.undecodableStream }
        let decoded = copied as Data
        try checkBudget(adding: decoded.count)
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
            throw StampRefusal.unknownStreamFormat
        }
        try set(number, Self.streamBody(entries: entries, data: data))
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
            throw StampRefusal.nestedTooDeep(limit: Self.maxDepth)
        }
    }

    /// The finished file, with `root` as the catalog.
    func data(root: Int) throws -> Data {
        var out = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = []
        for (index, body) in bodies.enumerated() {
            guard let body else { throw StampRefusal.unwrittenObject(number: index + 1) }
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

    /// Keys from `entries(of:)` are already escaped names (marked by a
    /// leading NUL); other keys are plain ASCII written here.
    static func dictionaryBody(_ entries: [(String, Data)]) -> Data {
        var out = Data("<<".utf8)
        for (key, value) in entries {
            out.append(Data(" ".utf8))
            if key.hasPrefix("\u{0}") {
                out.append(Data(key.dropFirst().utf8))
            } else {
                out.append(name(bytes: Array(key.utf8)))
            }
            out.append(Data(" ".utf8))
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

    /// A number in plain decimal notation that reads back as the same value:
    /// the shortest round-trip digits, with any exponent written out.
    static func number(_ value: CGFloat) throws -> String {
        guard value.isFinite else { throw StampRefusal.nonFiniteNumber }
        if value == 0 { return "0" }
        let text = "\(Double(value))"
        guard let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) else {
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
        guard let exponent = Int(text[text.index(after: e)...]) else { throw StampRefusal.unreadable(.number) }
        var mantissa = String(text[..<e])
        let negative = mantissa.hasPrefix("-")
        if negative { mantissa.removeFirst() }
        let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        let digits = String(parts[0]) + (parts.count > 1 ? String(parts[1]) : "")
        let point = parts[0].count + exponent
        var out: String
        if point <= 0 {
            out = "0." + String(repeating: "0", count: -point) + digits
        } else if point >= digits.count {
            out = digits + String(repeating: "0", count: point - digits.count)
        } else {
            out = String(digits.prefix(point)) + "." + String(digits.dropFirst(point))
        }
        if out.contains(".") {
            while out.hasSuffix("0") { out.removeLast() }
            if out.hasSuffix(".") { out.removeLast() }
        }
        return (negative ? "-" : "") + out
    }

    /// The bytes of a NUL-terminated C string.
    static func bytes(_ pointer: UnsafePointer<CChar>) -> [UInt8] {
        Array(UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                                  count: strlen(pointer)))
    }

    /// A dictionary key from `entries(of:)`: the escaped name behind a NUL.
    static func nameKey(_ bytes: [UInt8]) -> String {
        "\u{0}" + String(decoding: name(bytes: bytes), as: UTF8.self)
    }

    /// A name written from its bytes, any byte outside printable ASCII or a
    /// delimiter escaped as #XX.
    static func name(bytes: [UInt8]) -> Data {
        var out = Data("/".utf8)
        for byte in bytes {
            let delimiter = "()<>[]{}/%#".utf8.contains(byte)
            if byte < 0x21 || byte > 0x7E || delimiter {
                out.append(Data(String(format: "#%02X", byte).utf8))
            } else {
                out.append(byte)
            }
        }
        return out
    }

    static func name(_ name: String) -> String {
        String(decoding: self.name(bytes: Array(name.utf8)), as: UTF8.self)
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
            throw StampRefusal.compressionFailed
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
