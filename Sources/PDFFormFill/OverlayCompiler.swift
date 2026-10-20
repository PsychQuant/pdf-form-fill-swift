import CoreGraphics
import Foundation
import PDFVisualDiff

/// Compiles an overlay .tex into a one-page PDF of a required size.
///
/// The engine runs twice (TikZ `remember picture` needs the second pass to
/// place nodes) with its output directory set to a fresh temporary directory,
/// so nothing is written next to the source file. The source is copied into
/// that directory under a fixed name, so its file name never reaches TeX's
/// command line. The working directory is the source file's directory, so
/// relative paths in the .tex resolve as the author expects.
///
/// The .tex is trusted input: TeX can read any file the user can. The engine
/// runs with `-no-shell-escape`, and a run that does not finish within the
/// timeout is stopped.
public struct OverlayCompiler: Sendable {
    /// An engine name looked up on PATH (and in the usual TeX locations), or a path.
    public let engine: String

    public init(engine: String = "xelatex") {
        self.engine = engine
    }

    /// Seconds one compile may take, both passes together.
    public static let defaultTimeout: Double = 120

    /// Prefix of the temporary directories this compiler creates.
    static let directoryPrefix = "pdf-form-fill-"

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

    /// The engine's arguments; the source has been copied to
    /// `overlay.tex` in `outputDirectory`.
    static func engineArguments(outputDirectory: URL) -> [String] {
        ["-no-shell-escape", "-interaction=nonstopmode", "-halt-on-error",
         "-output-directory=\(outputDirectory.path)", "-jobname=overlay",
         outputDirectory.appendingPathComponent("overlay.tex").path]
    }

    /// Compiles `tex` and returns the overlay PDF, which lives in a fresh
    /// temporary directory owned by the caller; pass it to `discard(_:)` when
    /// done. The page must be `pageSize` within 0.01 bp (A4 by default).
    public func compile(tex: URL, pageSize: CGSize = PageGeometry.a4,
                        timeout: Double = OverlayCompiler.defaultTimeout) throws -> URL {
        guard timeout.isFinite, timeout > 0 else { throw FormFillError.invalidTimeout(timeout) }
        guard let executable = Self.locate(engine) else {
            throw FormFillError.engineNotFound(engine)
        }
        // A symbolic link is followed, so relative paths resolve next to the real file.
        let tex = tex.resolvingSymlinksInPath()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.directoryPrefix)\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            // The contents, not the item: a relative link would dangle there.
            try Data(contentsOf: tex).write(to: output.appendingPathComponent("overlay.tex"))
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw FormFillError.outputWriteFailed(output.path)
        }
        do {
            return try run(executable, in: output, source: tex, pageSize: pageSize, timeout: timeout)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Removes the temporary directory of an overlay returned by `compile`.
    /// Only a directory this compiler creates is removed: one whose name
    /// starts with the prefix, directly inside the temporary directory, and
    /// holding the copied `overlay.tex`. Anything else is left alone.
    public static func discard(_ overlay: URL) {
        let directory = overlay.deletingLastPathComponent().resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard directory.lastPathComponent.hasPrefix(directoryPrefix),
              directory.deletingLastPathComponent().standardizedFileURL.path == temporary.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("overlay.tex").path)
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(_ executable: URL, in output: URL, source tex: URL, pageSize: CGSize, timeout: Double) throws -> URL {
        let log = output.appendingPathComponent("overlay.log")
        let deadline = Date().addingTimeInterval(timeout)
        for _ in 0..<2 {
            let process = Process()
            process.executableURL = executable
            process.arguments = Self.engineArguments(outputDirectory: output)
            process.currentDirectoryURL = tex.deletingLastPathComponent()
            var environment = ProcessInfo.processInfo.environment
            // The engine calls helpers (xdvipdfmx) from its own directory.
            environment["PATH"] = executable.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do {
                try process.run()
            } catch {
                throw FormFillError.engineNotFound(executable.path)
            }
            if finished.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut {
                Self.stop(process)
                throw FormFillError.compilationTimedOut(seconds: timeout)
            }
            guard process.terminationStatus == 0 else {
                throw FormFillError.compilationFailed(logTail: Self.tail(of: log))
            }
        }
        let pdf = output.appendingPathComponent("overlay.pdf")
        guard let document = CGPDFDocument(pdf as CFURL) else {
            throw FormFillError.compilationFailed(logTail: Self.tail(of: log))
        }
        guard document.numberOfPages == 1, let page = document.page(at: 1) else {
            throw FormFillError.overlayPageCount(document.numberOfPages)
        }
        let size = page.getBoxRect(.cropBox).size
        guard abs(size.width - pageSize.width) <= PageGeometry.exactTolerance,
              abs(size.height - pageSize.height) <= PageGeometry.exactTolerance else {
            throw FormFillError.overlayWrongSize(width: Double(size.width), height: Double(size.height),
                                                 expectedWidth: Double(pageSize.width),
                                                 expectedHeight: Double(pageSize.height))
        }
        return pdf
    }

    /// Stops the engine and the helpers it started (xdvipdfmx and the like):
    /// children first, so none is left behind, then the engine itself.
    private static func stop(_ process: Process) {
        let pid = process.processIdentifier
        let killChildren = Process()
        killChildren.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        killChildren.arguments = ["-KILL", "-P", String(pid)]
        killChildren.standardOutput = FileHandle.nullDevice
        killChildren.standardError = FileHandle.nullDevice
        if (try? killChildren.run()) != nil { killChildren.waitUntilExit() }
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { kill(pid, SIGKILL) }
        process.waitUntilExit()
    }

    /// The last lines of a log, or a note that there is none.
    static func tail(of log: URL, lines: Int = 20) -> String {
        guard let data = try? Data(contentsOf: log) else { return "(no log was written)" }
        // TeX logs are not always valid UTF-8; keep what decodes.
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
