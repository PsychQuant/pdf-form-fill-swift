/// Fill a blank PDF form without touching it.
///
/// Only the typed text is typeset (in TeX, on an A4 page with a top-left
/// origin in bp). The compiled overlay is stamped 1:1 onto a copy of the
/// original page, and the result is verified pixel by pixel against the
/// original with PDFVisualDiff.
public enum PDFFormFill {}
