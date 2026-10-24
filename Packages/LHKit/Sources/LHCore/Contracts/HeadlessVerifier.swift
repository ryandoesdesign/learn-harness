import Foundation

/// One headless run of a demo document (headless.ts DemoRunResult).
public struct DemoRunResult: Sendable, Hashable {
	public var consoleErrors: [String]
	public var pageErrors: [String]
	public var failedRequests: [String]
	/// The probe expression's value (JSON), when one was given.
	public var probeResult: JSONValue?
	public var ok: Bool { consoleErrors.isEmpty && pageErrors.isEmpty && failedRequests.isEmpty }

	public init(consoleErrors: [String] = [], pageErrors: [String] = [], failedRequests: [String] = [], probeResult: JSONValue? = nil) {
		self.consoleErrors = consoleErrors
		self.pageErrors = pageErrors
		self.failedRequests = failedRequests
		self.probeResult = probeResult
	}
}

/// What the demo builder and visual maker need from a browser engine
/// (headless.ts HeadlessApi). LHWeb implements it over WebKit; LHAgent only
/// sees this protocol, so its tests run with a fake.
public protocol HeadlessVerifier: Sendable {
	/// Load `html` in the demo sandbox (the display CSP, opaque origin, no
	/// storage), settle, and report errors; evaluate `probe` if given.
	func runDemo(_ html: String, probe: String?) async throws -> DemoRunResult
	/// Render an SVG document to a single-IDAT PNG on white.
	func renderSvg(_ svg: String) async throws -> Data
}
