import CoreGraphics
import Foundation
import PDFVisualDiff

/// The outcome of filling a form. `passed` is false when any overlay check
/// found a pixel; the output file is written either way so it can be
/// inspected.
public struct FillResult: Sendable {
    public let output: URL
    public let pageSize: CGSize
    public let report: OverlayReport
    public var passed: Bool { report.passed }
}

/// Compile → stamp → verify, in one call.
public enum FormFiller {

    /// Everything that can be checked without the engine is checked first,
    /// so a bad resolution, an output path that names an input, or an
    /// unusable original fails before any file is written. The original is
    /// rendered before the output is written, and the overlay's temporary
    /// directory is removed when the call returns.
    public static func fill(tex: URL, output: URL, pageMode: PageMode = .a4, dpi: Double = 144,
                            engine: String = "xelatex", diffDirectory: URL? = nil,
                            timeout: Double = OverlayCompiler.defaultTimeout) throws -> FillResult {
        guard dpi.isFinite, dpi > 0, dpi <= PageRaster.maxDPI else { throw PDFVisualDiffError.invalidResolution(dpi) }
        guard timeout.isFinite, timeout > 0 else { throw FormFillError.invalidTimeout(timeout) }
        // A .tex reached through a symbolic link behaves like the file itself:
        // \BlankForm and TeX's relative paths resolve next to the real file.
        let tex = tex.resolvingSymlinksInPath()
        let original = try blankForm(for: tex)
        try FormStamper.refuseOverwriting(inputs: [(original, "blank form"), (tex, ".tex source")], with: output)
        let protected = [(output, "output"), (original, "blank form"), (tex, ".tex source")]
        try refuseArtifactCollisions(diffDirectory, protected)
        let target = try FormStamper.targetSize(original: original, pageMode: pageMode)
        let originalRaster = try PageRaster.render(url: original, pageIndex: 0, dpi: dpi)

        let overlay = try OverlayCompiler(engine: engine).compile(tex: tex, pageSize: target, timeout: timeout)
        defer { OverlayCompiler.discard(overlay) }
        // Ink beyond the overlay's page is clipped from every render, so the
        // overlay checks would never see typed text that was cut off.
        let offPage = try PageGeometry.inkOutsideCropBox(page: PageRaster.page(url: overlay, index: 0))
        guard offPage == 0 else { throw FormFillError.overlayInkOffPage(pixels: offPage) }
        // The render reaches one page beyond each edge; drawing placed
        // farther away is found from the content stream, wherever it is.
        let farAway = try ContentExtent.positionsFarOutside(page: PageRaster.page(url: overlay, index: 0))
        guard farAway == 0 else { throw FormFillError.overlayTextOffPage(characters: farAway) }
        try FormStamper.stamp(original: original, overlay: overlay, pageMode: pageMode, output: output)

        let verification = try OverlayVerifier.verify(
            original: originalRaster,
            output: PageRaster.render(url: output, pageIndex: 0, dpi: dpi),
            overlay: PageRaster.render(url: overlay, pageIndex: 0, dpi: dpi))
        if let diffDirectory {
            // Checked again now that the output exists, by file identity too.
            try refuseArtifactCollisions(diffDirectory, protected)
            try DiffArtifacts.write(diff: verification.diff, checks: verification.report.checks, to: diffDirectory)
        }
        let size = try PageRaster.page(url: output, index: 0).getBoxRect(.cropBox).size
        return FillResult(output: output, pageSize: size, report: verification.report)
    }

    private static func refuseArtifactCollisions(_ directory: URL?, _ protected: [(URL, String)]) throws {
        guard let directory, let hit = DiffArtifacts.collision(in: directory, with: protected) else { return }
        throw FormFillError.diffArtifactCollides(path: hit.artifact.path, role: hit.role)
    }

    /// The blank form named by `\newcommand{\BlankForm}{…}` or `\def\BlankForm{…}`
    /// in `tex`. A relative path is resolved against the .tex file's directory.
    public static func blankForm(for tex: URL) throws -> URL {
        let source: String
        do {
            source = try String(contentsOf: tex, encoding: .utf8)
        } catch {
            throw FormFillError.unreadableSource(tex.path)
        }
        let patterns = [#"\\newcommand\{\\BlankForm\}\{([^}]*)\}"#, #"\\def\\BlankForm\{([^}]*)\}"#]
        for pattern in patterns {
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = line.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                guard let range = code.range(of: pattern, options: .regularExpression) else { continue }
                let match = String(code[range])
                guard let open = match.lastIndex(of: "{") else { continue }
                let value = String(match[match.index(after: open)..<match.index(before: match.endIndex)])
                    .trimmingCharacters(in: .whitespaces)
                let expanded = (value as NSString).expandingTildeInPath
                let url = expanded.hasPrefix("/")
                    ? URL(fileURLWithPath: expanded)
                    : tex.deletingLastPathComponent().appendingPathComponent(expanded)
                let resolved = url.standardizedFileURL
                guard FileManager.default.fileExists(atPath: resolved.path) else {
                    throw FormFillError.blankFormNotFound(resolved.path)
                }
                return resolved
            }
        }
        throw FormFillError.blankFormMacroMissing(tex.path)
    }
}
