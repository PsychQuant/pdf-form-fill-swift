# pdf-form-fill-swift

Fill a blank PDF form without touching it, and prove it.

Only the typed text is typeset — in TeX, on an A4 page, with positions in bp
measured from the page's top-left corner. The compiled overlay is stamped 1:1
onto a copy of the original page with CoreGraphics (no scaling of either), and
the result is compared pixel by pixel against the original with
[pdf-visual-diff-swift](https://github.com/PsychQuant/pdf-visual-diff-swift).
Part of the macdoc toolchain ([PsychQuant/macdoc#240](https://github.com/PsychQuant/macdoc/issues/240)).

## Why not put the form inside TeX?

Placing the blank PDF under a TeX overlay (for example with pdfpages) rescales
it slightly and rounds its position, so every printed line moves by a fraction
of a pixel. Keeping the original out of TeX is the only way the result can
match the original pixel for pixel outside the typed text.

## Usage

```swift
import PDFFormFill

// 1. A skeleton with one commented \at line per printed label.
let skeleton = try FormSkeleton.generate(blankForm: blank, reference: "blank.pdf")

// 2. After editing the skeleton: compile, stamp, verify.
let result = try FormFiller.fill(tex: filledTex, output: filledPDF, pageMode: .a4, diffDirectory: diffDir)
print(result.passed, result.report.checks)
```

`FormFiller.fill` reads the blank form from `\newcommand{\BlankForm}{…}` (or
`\def\BlankForm{…}`) in the .tex; a relative path is resolved against the
.tex file's directory. The output is written even when a check fails, so it
can be inspected.

## Page size

- `.a4` (default): a near-A4 original (within 1.5 bp, for example the
  595.32 × 841.92 bp that Acrobat PDFMaker produces for A4) becomes exact
  A4 (210 × 297 mm) by keeping its top-left corner. Nothing is scaled; if the
  strip that would be removed contains ink, stamping is refused.
- `.original`: the original page size is kept.

## Requirements

- macOS 14 or later.
- A TeX engine for compiling overlays (default `xelatex`, looked up on PATH
  and in `/Library/TeX/texbin`). The skeleton uses `xeCJK` with `PingFang TC`;
  change `\setCJKmainfont` to any installed font.

## Known limitation

Labels are read with PDFKit. Labels printed on one baseline without a space
between them are merged by PDFKit, which spreads their positions evenly; treat
those skeleton positions as hints.

## License

MIT
