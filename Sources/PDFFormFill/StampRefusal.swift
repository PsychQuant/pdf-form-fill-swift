import Foundation

/// Why a PDF's objects could not be copied into the output. It is a case
/// rather than text, so a caller can word it in its own language.
public enum StampRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    /// An object of this kind could not be read.
    case unreadable(ObjectKind)
    /// A stream whose data lives in another file (/F).
    case externalStream
    /// A stream whose data cannot be decoded.
    case undecodableStream
    /// Objects nested deeper than `limit`.
    case nestedTooDeep(limit: Int)
    /// An infinite number or one that is not a number.
    case nonFiniteNumber
    /// The copy would exceed `limit` bytes.
    case tooLarge(limit: Int)
    /// A stream could not be compressed.
    case compressionFailed
    /// The overlay has optional content (layers) of its own, which cannot be
    /// merged with the original's.
    case overlayHasLayers
    /// The overlay's page content cannot be decoded.
    case undecodableOverlayContent
    /// A page's /Contents array holds something other than a stream.
    case contentEntryNotStream
    /// An object was reserved but never written (an internal error).
    case unwrittenObject(number: Int)

    public enum ObjectKind: String, Sendable {
        case name, string, number, array, dictionary, stream, unknown
    }

    public var description: String {
        switch self {
        case .unreadable(.unknown): return "unknown object type"
        case .unreadable(let kind): return "unreadable \(kind.rawValue)"
        case .externalStream: return "external stream"
        case .undecodableStream: return "undecodable stream"
        case .nestedTooDeep(let limit): return "objects nested deeper than \(limit)"
        case .nonFiniteNumber: return "non-finite number"
        case .tooLarge(let limit): return "the copy would exceed \(limit) bytes"
        case .compressionFailed: return "compression failed"
        case .overlayHasLayers: return "the overlay uses optional content (layers)"
        case .undecodableOverlayContent: return "undecodable overlay content"
        case .contentEntryNotStream: return "a page content entry is not a stream"
        case .unwrittenObject(let number): return "object \(number) was reserved but never written"
        }
    }
}
