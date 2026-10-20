import CoreGraphics
import Foundation
import PDFVisualDiff

/// Compiles an overlay .tex into a one-page A4 PDF.
///
/// The engine runs twice (TikZ `remember picture` needs the second pass to
/// place nodes) with its output directory set to a fresh temporary directory,
/// so nothing is written next to the source file. The working directory is
/// the source file's directory, so relative paths in the .tex resolve as the
/// author expects.
public struct OverlayCompiler: Sendable {
    /// An engine name looked up on PATH (and in the usual TeX locations), or a path.
    public let engine: String

    public init(engine: String = "xelatex") {
        self.engine = engine
    }

    /// Directories searched after PATH; GUI-launched processes and test
    /// runners often do not have the TeX bin directory on PATH.
    static let fallbackDirectories = ["/Library/TeX/texbin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    /// The engine's executable, or nil when it cannot be found.
    public static func locate(_ engine: String) -> URL? {
        let fm = FileManager.default
        if engine.contains("/") {
            return fm.isExecutableFile(atPath: engine) ? URL(fileURLWithPath: engine) : nil
        }
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for directory in path + fallbackDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(engine)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Returns the compiled overlay PDF, which lives in a temporary directory.
    public func compile(tex: URL) throws -> URL {
        guard let executable = Self.locate(engine) else {
            throw FormFillError.engineNotFound(engine)
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-form-fill-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        } catch {
            throw FormFillError.outputWriteFailed(output.path)
        }
        let log = output.appendingPathComponent("overlay.log")
        for _ in 0..<2 {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["-interaction=nonstopmode", "-halt-on-error",
                                 "-output-directory=\(output.path)", "-jobname=overlay", tex.lastPathComponent]
            process.currentDirectoryURL = tex.deletingLastPathComponent()
            var environment = ProcessInfo.processInfo.environment
            // The engine calls helpers (xdvipdfmx) from its own directory.
            environment["PATH"] = executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw FormFillError.engineNotFound(executable.path)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw FormFillError.compilationFailed(log: log.path)
            }
        }
        let pdf = output.appendingPathComponent("overlay.pdf")
        guard let document = CGPDFDocument(pdf as CFURL) else {
            throw FormFillError.compilationFailed(log: log.path)
        }
        guard document.numberOfPages == 1, let page = document.page(at: 1) else {
            throw FormFillError.overlayPageCount(document.numberOfPages)
        }
        let size = page.getBoxRect(.cropBox).size
        guard PageGeometry.classify(size) == .exactA4 else {
            throw FormFillError.overlayNotA4(width: Double(size.width), height: Double(size.height))
        }
        return pdf
    }
}
