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
		.library(name: "LHAnthropic", targets: ["LHAnthropic"]),
		.library(name: "LHAgent", targets: ["LHAgent"]),
		.library(name: "LHMarkdown", targets: ["LHMarkdown"]),
		.library(name: "LHWeb", targets: ["LHWeb"]),
	],
	dependencies: [
		.package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
		.package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0"),
	],
	targets: [
		// Pure domain ports of src/core — Foundation + CryptoKit only.
		.target(name: "LHCore"),
		.target(name: "LHResources", resources: [.copy("Resources/models.json"), .copy("Resources/mermaid.min.js"), .copy("Resources/mathjax-svg.js"), .copy("Resources/prompts"), .copy("Resources/prompt-gates.json")]),
		// GRDB schema/migrations/repositories, Keychain, security-scoped bookmarks.
		.target(name: "LHStore", dependencies: ["LHCore", .product(name: "GRDB", package: "GRDB.swift")]),
		// One-time importer from the TS app's data dir.
		.target(name: "LHImport", dependencies: ["LHCore", "LHStore"]),
		// Messages API client: request building, SSE streaming, retries, transports.
		.target(name: "LHAnthropic", dependencies: ["LHCore"]),
		// Agent loop, wire projection, tools, session engine; the teaching
		// agents, turn service, steers and compaction (M5).
		.target(name: "LHAgent", dependencies: ["LHCore", "LHAnthropic", "LHStore", "LHResources"]),
		// Message text → block model (math split out, GFM, mermaid, callouts);
		// TeX → SVG through MathJax in JavaScriptCore.
		.target(name: "LHMarkdown", dependencies: [
			"LHCore",
			"LHResources",
			.product(name: "Markdown", package: "swift-markdown"),
		]),
		// The shared hidden WKWebView: mermaid and figure snapshots, live diagram overlay.
		.target(name: "LHWeb", dependencies: ["LHCore", "LHResources"]),
		.testTarget(name: "LHMarkdownTests", dependencies: ["LHMarkdown", "LHCore"]),
		.testTarget(name: "LHWebTests", dependencies: ["LHWeb"]),
		.testTarget(name: "LHAnthropicTests", dependencies: ["LHAnthropic", "LHCore"], resources: [.copy("Fixtures")]),
		.testTarget(name: "LHAgentTests", dependencies: ["LHAgent", "LHAnthropic", "LHCore", "LHStore", "LHResources"], resources: [.copy("Fixtures"), .copy("Golden")]),
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
