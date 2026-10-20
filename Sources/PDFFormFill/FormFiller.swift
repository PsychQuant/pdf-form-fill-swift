import CoreGraphics
import Foundation
import PDFVisualDiff

/// The outcome of filling a form. `passed` is false when any of the four
/// overlay checks found a pixel; the output file is written either way so
/// it can be inspected.
public struct FillResult: Sendable {
    public let output: URL
    public let pageSize: CGSize
    public let report: OverlayReport
    public var passed: Bool { report.passed }
}

/// Compile → stamp → verify, in one call.
public enum FormFiller {

    public static func fill(tex: URL, output: URL, pageMode: PageMode = .a4, dpi: Double = 144,
                            engine: String = "xelatex", diffDirectory: URL? = nil) throws -> FillResult {
        let original = try blankForm(for: tex)
        let overlay = try OverlayCompiler(engine: engine).compile(tex: tex)
        try FormStamper.stamp(original: original, overlay: overlay, pageMode: pageMode, output: output)

        let verification = try OverlayVerifier.verify(
            original: PageRaster.render(url: original, pageIndex: 0, dpi: dpi),
            output: PageRaster.render(url: output, pageIndex: 0, dpi: dpi),
            overlay: PageRaster.render(url: overlay, pageIndex: 0, dpi: dpi))
        if let diffDirectory {
            try DiffArtifacts.write(diff: verification.diff, checks: verification.report.checks, to: diffDirectory)
        }
        let size = try PageRaster.page(url: output, index: 0).getBoxRect(.cropBox).size
        return FillResult(output: output, pageSize: size, report: verification.report)
    }

    /// The blank form named by `\newcommand{\BlankForm}{…}` or `\def\BlankForm{…}`
    /// in `tex`. A relative path is resolved against the .tex file's directory.
    public static func blankForm(for tex: URL) throws -> URL {
        let source: String
        do {
            source = try String(contentsOf: tex, encoding: .utf8)
        } catch {
            throw FormFillError.blankFormMacroMissing(tex.path)
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
