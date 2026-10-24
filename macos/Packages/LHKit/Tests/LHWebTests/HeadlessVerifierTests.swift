import Foundation
import Testing
import LHCore
@testable import LHWeb

// The demo sandbox in real WebKit (docs/native-macos-m6.md): a clean demo
// passes, a throwing one fails with its message, network beyond the CDN
// hosts is blocked and reported, probes evaluate, and figure PNGs are
// single-IDAT (headless-png).

@MainActor
@Suite(.serialized) struct HeadlessVerifierTests {
	let verifier: WebHeadlessVerifier = {
		let v = WebHeadlessVerifier()
		v.settle = .milliseconds(300)
		return v
	}()

	@Test func aCleanDemoPassesAndItsProbeEvaluates() async throws {
		let html = """
			<!doctype html><html><head><title>t</title></head><body>
			<input id="a"><input id="b"><script>document.body.dataset.ready = "yes";</script></body></html>
			"""
		let r = try await verifier.runDemo(html, probe: "({ inputs: document.querySelectorAll('input').length, ready: document.body.dataset.ready })")
		#expect(r.ok, "\(r)")
		#expect(r.probeResult == JSONValue.object(JSONObject(["inputs": .number(2), "ready": .string("yes")])))
	}

	@Test func aThrowingDemoFailsWithItsMessage() async throws {
		let r = try await verifier.runDemo("<!doctype html><body><script>console.error('bad thing'); null.x;</script></body>", probe: nil)
		#expect(!r.ok)
		#expect(r.consoleErrors == ["bad thing"])
		#expect(r.pageErrors.count == 1)
		#expect(r.pageErrors == ["null is not an object (evaluating 'null.x')"], "\(r)")
	}

	@Test func anUnhandledRejectionIsAnUncaughtError() async throws {
		let r = try await verifier.runDemo("<body><script>Promise.reject(new Error('nope'))</script></body>", probe: nil)
		#expect(r.pageErrors == ["Unhandled rejection: nope"])
	}

	@Test func networkOutsideTheCdnHostsIsBlockedAndReported() async throws {
		let r = try await verifier.runDemo(#"<!doctype html><body><img src="https://example.com/x.png"><script>fetch("https://example.com/data").catch(() => {})</script></body>"#, probe: nil)
		#expect(!r.ok)
		#expect(r.failedRequests.contains { $0.contains("example.com") }, "\(r.failedRequests)")
	}

	@Test func aProbeThatThrowsIsReported() async throws {
		let r = try await verifier.runDemo("<body></body>", probe: "document.querySelector('#none').value")
		#expect(r.pageErrors.count == 1)
		#expect(r.pageErrors.first?.hasPrefix("probe failed:") == true)
	}

	@Test func storageNeverOutlivesTheRun() async throws {
		let r = try await verifier.runDemo("<body></body>", probe: "(() => { try { localStorage.setItem('k', 'v'); return localStorage.getItem('k'); } catch (e) { return 'blocked'; } })()")
		#expect(r.ok)
		let again = try await verifier.runDemo("<body></body>", probe: "(() => { try { return localStorage.getItem('k'); } catch (e) { return 'blocked'; } })()")
		#expect(again.probeResult == JSONValue.null || again.probeResult == JSONValue.string("blocked"), "\(String(describing: again.probeResult))")
	}

	@Test func aDocumentCannotWidenTheHeaderPolicy() async throws {
		let html = #"<!doctype html><head><meta http-equiv="Content-Security-Policy" content="default-src *"></head><body><img src="https://example.com/y.png"></body>"#
		let r = try await verifier.runDemo(html, probe: nil)
		#expect(r.failedRequests.contains { $0.contains("example.com") }, "\(r)")
	}

	@Test func eachRunGetsAFreshOrigin() async throws {
		let a = try await verifier.runDemo("<body></body>", probe: "location.origin")
		let b = try await verifier.runDemo("<body></body>", probe: "location.origin")
		#expect(a.probeResult != b.probeResult)
		#expect(a.probeResult?.stringValue?.hasPrefix("lhdemo://") == true)
	}

	@Test func figurePngsAreTwiceSizeAndSingleIDAT() async throws {
		let png = try await verifier.renderSvg(##"<svg xmlns="http://www.w3.org/2000/svg" width="300" height="200"><rect x="10" y="10" width="280" height="180" fill="#36c"/></svg>"##)
		let chunks = pngChunks(png)
		#expect(chunks.filter { $0.type == "IDAT" }.count == 1)
		let ihdr = try #require(chunks.first { $0.type == "IHDR" })
		#expect(be32(ihdr.data, 0) == 600)
		#expect(be32(ihdr.data, 4) == 400)
	}
}

private func be32(_ d: Data, _ at: Int) -> Int {
	d[d.startIndex + at..<d.startIndex + at + 4].reduce(0) { $0 << 8 | Int($1) }
}

private func pngChunks(_ png: Data) -> [(type: String, data: Data)] {
	var out: [(String, Data)] = []
	var i = 8
	while i + 8 <= png.count {
		let len = be32(png, i)
		let type = String(decoding: png[png.startIndex + i + 4..<png.startIndex + i + 8], as: UTF8.self)
		out.append((type, png.subdata(in: i + 8..<i + 8 + len)))
		i += 12 + len
	}
	return out
}
