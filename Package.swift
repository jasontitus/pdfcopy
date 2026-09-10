// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PDFCopy",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "PDFCopyCore", targets: ["PDFCopyCore"]),
               .executable(name: "PDFCopy", targets: ["PDFCopy"])],
    targets: [.target(name: "PDFCopyCore"),
              .executableTarget(name: "PDFCopy", dependencies: ["PDFCopyCore"]),
              .testTarget(name: "PDFCopyCoreTests", dependencies: ["PDFCopyCore"]),
              .testTarget(name: "PDFCopyAppTests", dependencies: ["PDFCopy"])]
)
