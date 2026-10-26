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

    /// Directories created by `compile` and not yet discarded. Ownership is
    /// recorded here, never inferred from a name.
    private static let owned = OwnedDirectories()

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
        // The contents, not the item: a relative link would dangle there.
        let contents: Data
        do {
            contents = try Data(contentsOf: tex)
        } catch {
            throw FormFillError.unreadableSource(tex.path)
        }
        do {
            // Private: the copied source holds the typed text.
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            Self.owned.insert(output)
            try contents.write(to: output.appendingPathComponent("overlay.tex"))
        } catch {
            Self.remove(output)
            throw FormFillError.outputWriteFailed(output.path)
        }
        do {
            return try run(executable, in: output, source: tex, pageSize: pageSize, timeout: timeout)
        } catch {
            Self.remove(output)
            throw error
        }
    }

    /// Removes the temporary directory of an overlay returned by `compile`
    /// in this process. Any other directory is left alone, whatever its name.
    public static func discard(_ overlay: URL) {
        let directory = overlay.deletingLastPathComponent()
        guard owned.contains(directory) else { return }
        remove(directory)
    }

    private static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        owned.remove(directory)
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
        // A character the font lacks is dropped from the PDF with only a log
        // line, so no pixel check can see that it is missing.
        let dropped = Self.droppedCharacters(in: log)
        guard dropped.stray.isEmpty else { throw FormFillError.textOutsideNodes(dropped.stray) }
        guard dropped.missing.isEmpty else { throw FormFillError.missingCharacters(dropped.missing) }
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

    /// The characters the engine left out, from its log ("Missing character:
    /// There is no X … in font F!"), in order, once each: `missing` are those
    /// a font lacks; `stray` are those typeset in nullfont, which is text in
    /// the picture outside any node. Either way the PDF does not have them,
    /// and no pixel check can see what was never drawn.
    static func droppedCharacters(in log: URL) -> (missing: [String], stray: [String]) {
        guard let data = try? Data(contentsOf: log) else { return ([], []) }
        let text = String(decoding: data, as: UTF8.self)
        var missing: [String] = [], stray: [String] = []
        for line in text.split(separator: "\n") {
            guard let start = line.range(of: "Missing character: There is no ") else { continue }
            let rest = line[start.upperBound...]
            guard let end = rest.range(of: " in font") else { continue }
            var character = String(rest[..<end.lowerBound])
            for marker in [" (U+", " (\""] {
                if let code = character.range(of: marker) { character = String(character[..<code.lowerBound]) }
            }
            guard !character.isEmpty else { continue }
            if line.contains("in font nullfont") {
                if !stray.contains(character) { stray.append(character) }
            } else if !missing.contains(character) {
                missing.append(character)
            }
        }
        return (missing, stray)
    }

    /// Stops the engine and the processes it started (xdvipdfmx and the
    /// like). Process starts the engine as the leader of its own process
    /// group, so signalling the group also reaches descendants orphaned by
    /// an exited parent; descendants still attached to the tree are found by
    /// walking it, in case one changed its group. Everything is frozen first
    /// so nothing new is spawned, then killed.
    private static func stop(_ process: Process) {
        let pid = process.processIdentifier
        kill(-pid, SIGSTOP)
        kill(pid, SIGSTOP)
        var tree: [pid_t] = []
        var frontier = [pid]
        while let parent = frontier.popLast() {
            for child in children(of: parent) where !tree.contains(child) {
                kill(child, SIGSTOP)
                tree.append(child)
                frontier.append(child)
            }
        }
        kill(-pid, SIGKILL)
        for child in tree.reversed() { kill(child, SIGKILL) }
        if process.isRunning { kill(pid, SIGKILL) }
        process.waitUntilExit()
    }

    /// Direct children of `pid`, from pgrep.
    private static func children(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
    }

    /// The last lines of a log, or a note that there is none.
    static func tail(of log: URL, lines: Int = 20) -> String {
        guard let data = try? Data(contentsOf: log) else { return "(no log was written)" }
        // TeX logs are not always valid UTF-8; keep what decodes.
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}

/// A thread-safe set of directory paths.
final class OwnedDirectories: @unchecked Sendable {
    private let lock = NSLock()
    private var paths = Set<String>()

    private func key(_ url: URL) -> String { url.standardizedFileURL.path }

    func insert(_ url: URL) { lock.withLock { _ = paths.insert(key(url)) } }
    func remove(_ url: URL) { lock.withLock { _ = paths.remove(key(url)) } }
    func contains(_ url: URL) -> Bool { lock.withLock { paths.contains(key(url)) } }
}
