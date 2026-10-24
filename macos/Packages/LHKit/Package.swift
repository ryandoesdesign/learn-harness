// swift-tools-version: 6.4
import PackageDescription

let package = Package(
	name: "LHKit",
	platforms: [.macOS(.v27)],
	products: [
		.library(name: "LHCore", targets: ["LHCore"]),
		.library(name: "LHResources", targets: ["LHResources"]),
		.library(name: "LHStore", targets: ["LHStore"]),
		.library(name: "LHImport", targets: ["LHImport"]),
	],
	dependencies: [
		.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
	],
	targets: [
		// Pure domain ports of src/core — Foundation + CryptoKit only.
		.target(name: "LHCore"),
		.target(name: "LHResources", resources: [.copy("Resources/models.json")]),
		// GRDB schema/migrations/repositories, Keychain, security-scoped bookmarks.
		.target(name: "LHStore", dependencies: ["LHCore", .product(name: "GRDB", package: "GRDB.swift")]),
		// One-time importer from the TS app's data dir.
		.target(name: "LHImport", dependencies: ["LHCore", "LHStore"]),
		.testTarget(name: "LHStoreTests", dependencies: ["LHStore", "LHCore"]),
		.testTarget(name: "LHImportTests", dependencies: ["LHImport", "LHStore", "LHCore"]),
		.testTarget(
			name: "LHCoreTests",
			dependencies: ["LHCore", "LHResources"],
			resources: [.copy("Golden")]
		),
	],
	swiftLanguageModes: [.v6]
)
