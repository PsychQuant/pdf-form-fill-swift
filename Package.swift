// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pdf-form-fill-swift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PDFFormFill", targets: ["PDFFormFill"])
    ],
    dependencies: [
        .package(url: "https://github.com/PsychQuant/pdf-visual-diff-swift.git", .upToNextMinor(from: "0.6.0"))
    ],
    targets: [
        .target(
            name: "PDFFormFill",
            dependencies: [.product(name: "PDFVisualDiff", package: "pdf-visual-diff-swift")]
        ),
        .testTarget(
            name: "PDFFormFillTests",
            dependencies: [
                "PDFFormFill",
                .product(name: "PDFVisualDiff", package: "pdf-visual-diff-swift"),
            ]
        )
    ]
)
