import Foundation
import Testing
import LHCore
import LHWeb
@testable import Aster

// The demo sandbox inside the sandboxed app (docs/native-macos-m6.md): the
// private scheme, the CSP header and the error hooks behave the same under
// the app's entitlements as in the package tests.

@MainActor
@Suite(.serialized) struct DemoSandboxHostTests {
	@Test func aPassingDemoPasses() async throws {
		let r = try await WebHeadlessVerifier.shared.runDemo("<!doctype html><body><input><script>document.body.dataset.ok = 1</script></body>", probe: "document.body.dataset.ok")
		#expect(r.ok, "\(r)")
		#expect(r.probeResult == JSONValue.string("1"))
	}

	@Test func aThrowingDemoReportsItsMessage() async throws {
		let r = try await WebHeadlessVerifier.shared.runDemo("<!doctype html><body><script>undefinedFn()</script></body>", probe: nil)
		#expect(r.pageErrors.count == 1)
		#expect(r.pageErrors.first?.contains("undefinedFn") == true, "\(r.pageErrors)")
	}

	@Test func anOffListHostIsBlocked() async throws {
		let r = try await WebHeadlessVerifier.shared.runDemo(#"<!doctype html><body><script src="https://example.com/x.js"></script></body>"#, probe: nil)
		#expect(r.failedRequests.contains { $0.contains("example.com") }, "\(r)")
	}

	/// Network: a real CDN script loads under the sandbox (opt-in).
	@Test(.enabled(if: ProcessInfo.processInfo.environment["LH_LIVE"] == "1"))
	func aCdnScriptLoads() async throws {
		let html = #"<!doctype html><body><script src="https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js"></script></body>"#
		let r = try await WebHeadlessVerifier.shared.runDemo(html, probe: "typeof _.chunk")
		#expect(r.ok, "\(r)")
		#expect(r.probeResult == JSONValue.string("function"))
	}

	@Test func theGalleryDemoIsARealDemo() async throws {
		let record = RenderGallery.record()
		let steer = try #require(record.messages.first { $0.id == "steer_job_d" }?.marker)
		let html = try #require(steer.details["result"]?["html"]?.stringValue)
		let r = try await WebHeadlessVerifier.shared.runDemo(html, probe: "document.getElementById('v').textContent")
		#expect(r.ok, "\(r)")
		#expect(r.probeResult == JSONValue.string("40%"))
	}
}
