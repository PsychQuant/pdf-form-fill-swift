import AppKit
import Foundation
import PDFKit
import PDFVisualDiff

/// A run of printed text on the blank form, in bp with a top-left origin.
public struct FormLabel: Equatable, Sendable {
    public let text: String
    public let left: Double
    public let right: Double
    public let top: Double
    public let bottom: Double
    public let baseline: Double
    public let fontSize: Double
}

/// Writes the .tex overlay skeleton for a blank form.
public enum FormSkeleton {

    /// The printed labels of page 1, in PDFKit's reading order. A label is a
    /// run of non-whitespace characters on one baseline. Labels that the PDF
    /// draws on one baseline without a space between them are merged by
    /// PDFKit, which then spreads their positions evenly; such positions are
    /// hints only.
    public static func labels(in blankForm: URL) throws -> [FormLabel] {
        guard let document = PDFDocument(url: blankForm) else {
            throw FormFillError.unreadablePDF(blankForm.path)
        }
        guard let page = document.page(at: 0) else {
            throw FormFillError.emptyPDF(blankForm.path)
        }
        let box = page.bounds(for: .cropBox)
        let text = (page.string ?? "") as NSString
        // One attributed string for the page: asking each selection for its
        // own makes PDFKit log two lines per character on stderr.
        let attributed = page.attributedString
        var labels: [FormLabel] = []
        var current: (text: String, left: Double, right: Double, top: Double, bottom: Double, baseline: Double, size: Double)?

        func close() {
            if let run = current {
                labels.append(FormLabel(text: run.text, left: run.left, right: run.right, top: run.top,
                                        bottom: run.bottom, baseline: run.baseline, fontSize: run.size))
            }
            current = nil
        }

        for index in 0..<text.length {
            let character = text.substring(with: NSRange(location: index, length: 1))
            guard character.rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil,
                  let selection = page.selection(for: NSRange(location: index, length: 1)) else {
                close()
                continue
            }
            let bounds = selection.bounds(for: page)
            guard !bounds.isEmpty else { close(); continue }
            let font = index < (attributed?.length ?? 0)
                ? attributed?.attribute(.font, at: index, effectiveRange: nil) as? NSFont : nil
            let left = Double(bounds.minX - box.minX)
            let right = Double(bounds.maxX - box.minX)
            let top = Double(box.maxY - bounds.maxY)
            let bottom = Double(box.maxY - bounds.minY)
            let baseline = bottom - Double(abs(font?.descender ?? 0))
            let size = Double(font?.pointSize ?? bounds.height)
            if var run = current, abs(run.baseline - baseline) < 0.5, left >= run.right - 0.5, left - run.right < 0.5 {
                run.text += character
                run.right = right
                run.top = min(run.top, top)
                run.bottom = max(run.bottom, bottom)
                current = run
            } else {
                close()
                current = (character, left, right, top, bottom, baseline, size)
            }
        }
        close()
        return labels
    }

    /// Characters that TeX would read as markup inside `\BlankForm`'s value.
    static let unsafePathCharacters = CharacterSet(charactersIn: "\\{}%#^").union(.controlCharacters)

    /// The skeleton text. `reference` is written into `\BlankForm` as given
    /// (callers pass a path relative to where the .tex will live); it
    /// defaults to the form's absolute path. A path TeX would misread is
    /// refused.
    ///
    /// The overlay page gets the output's size: A4 for a form within 1.5 bp of
    /// A4 (page mode a4), the form's own size otherwise (page mode original).
    /// Every printed label gets an empty field macro in the settings section
    /// and a commented placement line that uses it.
    public static func generate(blankForm: URL, reference: String? = nil) throws -> String {
        let path = reference ?? blankForm.path
        guard path.unicodeScalars.allSatisfy({ !unsafePathCharacters.contains($0) }) else {
            throw FormFillError.unsafeBlankFormPath(path)
        }
        let labels = try labels(in: blankForm)
        let size = try pageSize(of: blankForm)
        let nearA4 = PageGeometry.classify(size) != .other
        let paper = nearA4
            ? "a4paper"
            : String(format: "paperwidth=%.4fbp,paperheight=%.4fbp", size.width, size.height)
        let pageNote = nearA4
            ? "% The page is A4: fill with page mode a4 (the default)."
            : String(format: "%% The form is %.2f × %.2f bp, not near A4, so this page has the form's size:\n"
                     + "%% fill with page mode original (`macdoc pdf form-fill --page original`).", size.width, size.height)
        // A control character (a line break in particular) would end the comment.
        let name = String(String.UnicodeScalarView(blankForm.lastPathComponent.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? "?" : $0
        }))
        var lines: [String] = [
            "% Overlay for \(name), generated by pdf-form-fill-swift.",
            "%",
            "% Only the typed text belongs in this file. The blank form is never placed",
            "% in TeX: `macdoc pdf form-fill <this file>` compiles this overlay, stamps it",
            "% 1:1 onto a copy of \\BlankForm, and checks every pixel of the result",
            "% against the original.",
            pageNote,
            "%",
            "% Coordinates are in bp (1/72 inch) with the origin at the page's top-left",
            "% corner. \\at{x}{y}{size}{text} puts the left end of the text's baseline at",
            "% (x, y). \\atbox{x}{y}{width}{size}{text} does the same for a field of",
            "% several lines: the text wraps within width bp (xeCJK breaks lines between",
            "% CJK characters).",
            "%",
            "% Each printed label has a field macro in the settings section, and each",
            "% commented \\at line below marks one label and already names its macro:",
            "% fill in the macros you need, uncomment their lines and move them into the",
            "% fields. Labels printed on one line without a space between them get evenly",
            "% spread positions; treat those as hints.",
            "\\documentclass{article}",
            "\\usepackage[\(paper),margin=0pt]{geometry}",
            "\\usepackage{tikz}",
            "\\usetikzlibrary{calc}",
            "\\usepackage{xeCJK}",
            "\\setCJKmainfont{PingFang TC} % any installed font, e.g. DFKai-SB",
            "\\pagestyle{empty}",
            "",
            "% ===================== settings =====================",
            "\\newcommand{\\BlankForm}{\(path)}",
        ]
        for (index, label) in labels.enumerated() {
            lines.append("\\newcommand{\\\(fieldMacroName(index))}{} % \(printable(label.text))")
        }
        lines += [
            "% ====================================================",
            "",
            "\\newcommand{\\at}[3]{\\node[anchor=base west,inner sep=0pt,font=\\fontsize{#3}{#3}\\selectfont] at ($(current page.north west)+(#1 bp,-#2 bp)$)}",
            "\\newcommand{\\atbox}[5]{\\node[anchor=base west,inner sep=0pt,text width=#3 bp,align=left,font=\\fontsize{#4}{\\fpeval{1.25*#4}}\\selectfont] at ($(current page.north west)+(#1 bp,-#2 bp)$) {#5}}",
            "",
            "\\begin{document}",
            "\\null",
            "\\begin{tikzpicture}[remember picture,overlay]",
        ]
        for (index, label) in labels.enumerated() {
            lines.append("% \\at{\(bp(label.right + 2))}{\(bp(label.baseline))}{\(bp(label.fontSize))}{\\\(fieldMacroName(index))}; % \(printable(label.text)) (\(bp(label.left)), \(bp(label.baseline)))")
        }
        lines += ["\\end{tikzpicture}", "\\end{document}", ""]
        return lines.joined(separator: "\n")
    }

    /// `text` with every control character replaced by "?": label text is
    /// copied into comments, which a control character could end, and the
    /// skeleton may be printed on a terminal.
    static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? "?" : $0
        }))
    }

    /// `FieldA` … `FieldZ`, `FieldAA`, `FieldAB`, …: TeX macro names may
    /// only contain letters.
    static func fieldMacroName(_ index: Int) -> String {
        var n = index + 1, letters = ""
        while n > 0 {
            n -= 1
            letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters
            n /= 26
        }
        return "Field" + letters
    }

    private static func pageSize(of blankForm: URL) throws -> CGSize {
        guard let document = PDFDocument(url: blankForm), let page = document.page(at: 0) else {
            throw FormFillError.unreadablePDF(blankForm.path)
        }
        return page.bounds(for: .cropBox).size
    }

    private static func bp(_ value: Double) -> String {
        String(format: "%.1f", (value * 10).rounded() / 10)
    }
}
