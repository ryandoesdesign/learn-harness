// swift-tools-version: 6.4
import PackageDescription

let package = Package(
	name: "LHKit",
	platforms: [.macOS(.v27)],
	products: [
		.library(name: "LHCore", targets: ["LHCore"]),
		.library(name: "LHResources", targets: ["LHResources"]),
	],
	targets: [
		// Pure domain ports of src/core — Foundation + CryptoKit only.
		.target(name: "LHCore"),
		.target(name: "LHResources", resources: [.copy("Resources/models.json")]),
		.testTarget(
			name: "LHCoreTests",
			dependencies: ["LHCore", "LHResources"],
			resources: [.copy("Golden")]
		),
	],
	swiftLanguageModes: [.v6]
)
