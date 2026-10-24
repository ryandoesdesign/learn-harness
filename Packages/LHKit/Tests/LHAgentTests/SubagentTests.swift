import CoreGraphics
import CoreText
import Foundation
import Testing
import LHAnthropic
@testable import LHAgent
@testable import LHCore

// The sub-agent loops with a scripted model and a fake verifier (ports of
// the demos / visual / pdf-reader / researcher cases in tests/jobs.test.ts
// and tests/pdf-ops.test.ts): every gate — final verification, never an
// unlooked SVG, never an unread brief — and the PDFKit operations.

struct FakeVerifier: HeadlessVerifier {
	var demo: @Sendable (String) -> DemoRunResult = { _ in DemoRunResult() }
	var png = Data([0x89, 0x50, 0x4E, 0x47])
	func runDemo(_ html: String, probe: String?) async throws -> DemoRunResult { demo(html) }
	func renderSvg(_ svg: String) async throws -> Data { png }
}

final class Collected: @unchecked Sendable {
	private let lock = NSLock()
	private var _lines: [String] = []
	private var _steps = 0
	var lines: [String] { lock.withLock { _lines } }
	var steps: Int { lock.withLock { _steps } }
	func line(_ s: String) { lock.withLock { _lines.append(s) } }
	func usage(_ s: [UsageStepRecord]) { lock.withLock { _steps += s.count } }
}

private func model(_ responses: [ScriptedTransport.Response]) -> (SubagentModel, ScriptedTransport) {
	let t = ScriptedTransport(responses)
	return (SubagentModel(client: MessagesClient(transport: t, apiKey: { "sk-ant-test" }), spec: EffectiveModelSpec(model: "claude-opus-5-5", effort: .low)), t)
}

private func call(_ id: String, _ name: String, _ json: JSONValue) -> ScriptedSSE.Piece { .toolUse(id: id, name: name, json: json.serialized()) }
private func sse(_ pieces: [ScriptedSSE.Piece], tool: Bool = false) -> ScriptedTransport.Response {
	.sse(ScriptedSSE.message(pieces, stopReason: tool ? "tool_use" : "end_turn"))
}

/// A text PDF drawn with CoreText (one string per page; lines split on \n).
func makePdf(_ pages: [String]) throws -> URL {
	let url = FileManager.default.temporaryDirectory.appending(path: "lh-pdf-\(UUID().uuidString).pdf")
	var box = CGRect(x: 0, y: 0, width: 612, height: 792)
	let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
	for page in pages {
		ctx.beginPDFPage(nil)
		var y = 740.0
		for line in page.components(separatedBy: "\n") {
			let attr = NSAttributedString(string: line, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
			ctx.textPosition = CGPoint(x: 72, y: y)
			CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
			y -= 24
		}
		ctx.endPDFPage()
	}
	ctx.closePDF()
	return url
}

@Suite struct DemoBuilderTests {
	@Test func aTestedPassingDemoIsDeliveredWithItsNotes() async throws {
		let html = "<!doctype html><body>ok</body>"
		let (m, t) = model([
			sse([call("w", "write_demo", ["html": .string(html)])], tool: true),
			sse([call("r", "run_demo", [:])], tool: true),
			sse([.text("Drag the slider.")]),
		])
		let c = Collected()
		let r = await runDemoBuilder(title: " Slopes ", brief: "a slider", model: m, verifier: FakeVerifier(), onUsage: c.usage, onActivity: c.line)
		#expect(r == DemoResult(title: "Slopes", html: html, tested: true, notes: "Drag the slider."))
		#expect(c.lines == ["write_demo", "write_demo: 0.0 KB", "run_demo", "run_demo: clean"])
		#expect(c.steps == 3)
		let first = try JSONValue.parse(t.requestBodies[0])
		#expect(first["messages"]?[0]?["content"]?[0]?["text"]?.stringValue?.hasPrefix("Demo title: Slopes\nBrief (all you know about the lesson") == true)
		#expect(first["system"]?.arrayValue?.first?["text"]?.stringValue?.contains("cdnjs.cloudflare.com") == true, "the CDN-hosts line")
	}

	@Test func anUntestedDemoGetsAFinalVerificationAndFailsHonestly() async throws {
		let (m, _) = model([
			sse([call("w", "write_demo", ["html": "<body><script>boom()</script></body>"])], tool: true),
			sse([.text("Done.")]),
		])
		let v = FakeVerifier(demo: { _ in DemoRunResult(pageErrors: ["boom is not defined"]) })
		let r = await runDemoBuilder(title: "T", brief: "b", model: m, verifier: v, onUsage: { _ in }, onActivity: { _ in })
		#expect(r.html.isEmpty)
		#expect(r.notes == "FAILED: the demo never passed headless verification (1 page error — boom is not defined).")
	}

	@Test func aFailedRunTellsTheBuilderWhatBroke() async throws {
		let (m, t) = model([
			sse([call("w", "write_demo", ["html": "x"])], tool: true),
			sse([call("r", "run_demo", [:])], tool: true),
			sse([.text("gave up")]),
		])
		let v = FakeVerifier(demo: { _ in DemoRunResult(consoleErrors: ["e1"], failedRequests: ["https://x (blocked)"]) })
		_ = await runDemoBuilder(title: "T", brief: "b", model: m, verifier: v, onUsage: { _ in }, onActivity: { _ in })
		let third = try JSONValue.parse(t.requestBodies[2])
		let result = third["messages"]?.arrayValue?.last?["content"]?[0]?["content"]?[0]?["text"]?.stringValue
		#expect(result == "FAILED: 1 console error, 1 failed request.\nConsole errors:\n- e1\nFailed requests:\n- https://x (blocked)\nFix the document (write_demo) and re-test (run_demo).")
	}

	@Test func neverWritingIsAFailure() async throws {
		let (m, _) = model([sse([.text("I can't.")])])
		let r = await runDemoBuilder(title: "", brief: "", model: m, verifier: FakeVerifier(), onUsage: { _ in }, onActivity: { _ in })
		#expect(r == DemoResult(title: "Interactive demo", html: "", tested: true, notes: "FAILED: the builder never wrote a demo. (I can't.)"))
	}
}

@Suite struct VisualMakerTests {
	let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>"#

	@Test func anUnlookedFinishIsShownTheRenderFirst() async throws {
		let (m, t) = model([
			sse([call("w", "write_svg", ["svg": .string(svg)])], tool: true),
			sse([.text("Looks right.")]),
			sse([.text("Verified.")]),
		])
		let r = await runVisualMaker(brief: "a square", model: m, verifier: FakeVerifier(), onUsage: { _ in }, onActivity: { _ in })
		#expect(r == VisualResult(svg: svg, notes: "Verified."))
		let third = try JSONValue.parse(t.requestBodies[2])
		let nudge = try #require(third["messages"]?.arrayValue?.last?["content"]?.arrayValue)
		#expect(nudge.first?["text"]?.stringValue == UNLOOKED_FINISH_MESSAGE)
		#expect(nudge.last?["type"]?.stringValue == "image")
	}

	@Test func renderLooksAndEditsMustMatchOnce() async throws {
		let two = #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="5"/><rect width="10"/></svg>"#
		let (m, t) = model([
			sse([call("w", "write_svg", ["svg": .string(two)])], tool: true),
			sse([call("e", "edit_svg", ["old_text": "<rect", "new_text": "<circle"])], tool: true),
			sse([call("e2", "edit_svg", ["old_text": "<rect width=\"10\"", "new_text": "<rect fill=\"red\" width=\"10\""]), call("r", "render_svg", [:])], tool: true),
			sse([.text("Red square.")]),
		])
		let r = await runVisualMaker(brief: "b", model: m, verifier: FakeVerifier(), onUsage: { _ in }, onActivity: { _ in })
		#expect(r.svg.contains(#"<rect fill="red" width="10""#))
		#expect(r.notes == "Red square.")
		let third = try JSONValue.parse(t.requestBodies[2])
		let editResult = third["messages"]?.arrayValue?.last?["content"]?[0]
		#expect(editResult?["is_error"]?.boolValue == true)
		#expect(editResult?["content"]?[0]?["text"]?.stringValue == "ERROR: old_text appears 2 times — it must match EXACTLY ONCE. Include more surrounding context to make it unique.")
		let fourth = try JSONValue.parse(t.requestBodies[3])
		let last = try #require(fourth["messages"]?.arrayValue?.last?["content"]?.arrayValue)
		#expect(last.map { $0["type"]?.stringValue } == ["tool_result", "tool_result", "text", "image"], "the results, then the look")
		#expect(last[2]["text"]?.stringValue == LOOK_MESSAGE)
	}

	@Test func theIterationLimitDeliversOnlyAVerifiedSvg() async throws {
		let (m, _) = model([sse([call("w", "write_svg", ["svg": .string(svg)])], tool: true)])
		let r = await runVisualMaker(brief: "b", model: m, verifier: FakeVerifier(), maxIterations: 1, onUsage: { _ in }, onActivity: { _ in })
		#expect(r == VisualResult(svg: "", notes: "FAILED: iteration limit (1) reached without a verified SVG."))
	}
}

@Suite struct PdfTests {
	@Test func pageSpecsCoverAllRangesListsAndClamp() {
		#expect(parsePageSpec("all", total: 3) == [1, 2, 3])
		#expect(parsePageSpec(" ALL ", total: 2) == [1, 2])
		#expect(parsePageSpec("2-9", total: 4) == [2, 3, 4])
		#expect(parsePageSpec("3,1,1,7", total: 5) == [1, 3])
		#expect(parsePageSpec("0-2", total: 5) == [1, 2])
		#expect(parsePageSpec("x", total: 5) == [])
	}

	@Test func infoExtractSearchAndRenderReadTheDocument() async throws {
		let url = try makePdf(["Calculus notes\nThe derivative measures change.", "Eigenvectors keep direction\n∀x ∈ ℝ, ∑ ≤ ∞", "Appendix"])
		let doc = try PdfDocument(url)
		#expect(doc.pageCount == 3)
		let info = doc.info()
		#expect(info.pages.map(\.page) == [1, 2, 3])
		#expect(info.pages[1].mathDensity > info.pages[0].mathDensity)
		#expect(doc.text(1).contains("derivative"))
		#expect(doc.text(1).contains("\n"), "PDFKit keeps line breaks")
		let pngs = doc.render([1, 9], dpi: 72)
		#expect(pngs.map(\.page) == [1])
	}

	@Test func theReaderNudgesAnUnreadBriefThenCitesWhatItRead() async throws {
		let url = try makePdf(["Intro", "The derivative measures change."])
		let (m, t) = model([
			sse([.text("It is about calculus.")]),
			sse([call("i", "pdf_info", [:])], tool: true),
			sse([call("s", "pdf_search", ["query": "deriv"]), call("x", "pdf_extract", ["pages": "2"])], tool: true),
			sse([call("r", "pdf_render", ["pages": "all", "dpi": 72])], tool: true),
			sse([.text("The derivative measures change (p. 2).\nPages consulted: 2")]),
		])
		let c = Collected()
		let r = await runPdfReader(url: url, displayPath: "notes.pdf", question: "what is a derivative", model: m, onUsage: c.usage, onActivity: c.line)
		#expect(r.brief == "The derivative measures change (p. 2).\nPages consulted: 2")
		#expect(r.pagesRead == [1, 2])
		#expect(r.pagesConsulted == [1, 2])
		#expect(c.lines == ["pdf_info: triaging", "pdf_search: \"deriv\"", "pdf_extract: 2", "pdf_render: all @72dpi"])
		let second = try JSONValue.parse(t.requestBodies[1])
		#expect(second["messages"]?.arrayValue?.last?["content"]?[0]?["text"]?.stringValue == UNREAD_FINISH_MESSAGE
			|| second["messages"]?.arrayValue?.last?["content"]?.stringValue == UNREAD_FINISH_MESSAGE)
		let fourth = try JSONValue.parse(t.requestBodies[3])
		let results = try #require(fourth["messages"]?.arrayValue?.last?["content"]?.arrayValue)
		#expect(results[0]["content"]?[0]?["text"]?.stringValue == "=== Page 2, line 1 ===\n>>> The derivative measures change.")
		#expect(results[1]["content"]?[0]?["text"]?.stringValue == "--- Page 2 ---\nThe derivative measures change.")
		let fifth = try JSONValue.parse(t.requestBodies[4])
		let images = try #require(fifth["messages"]?.arrayValue?.last?["content"]?.arrayValue)
		#expect(images.first { $0["type"]?.stringValue == "text" }?["text"]?.stringValue == "The rendered page(s), in order (p1, p2):")
		#expect(images.filter { $0["type"]?.stringValue == "image" }.count == 2)
	}

	@Test func anUnreadableFileFailsBeforeAnyCall() async throws {
		let bad = FileManager.default.temporaryDirectory.appending(path: "lh-bad-\(UUID().uuidString).pdf")
		try Data("not a pdf".utf8).write(to: bad)
		let (m, t) = model([])
		let r = await runPdfReader(url: bad, displayPath: "bad.pdf", question: "q", model: m, onUsage: { _ in }, onActivity: { _ in })
		#expect(r.brief.hasPrefix("PDF failed: not a readable PDF"))
		#expect(t.requestBodies.isEmpty)
	}

	@Test func anInvalidSearchRegexIsAnErrorResult() async throws {
		let url = try makePdf(["x"])
		let (m, t) = model([
			sse([call("s", "pdf_search", ["query": "a(b"])], tool: true),
			sse([.text("Nothing found.")]),
			sse([.text("Nothing found.")]),
		])
		_ = await runPdfReader(url: url, displayPath: "x.pdf", question: "q", model: m, onUsage: { _ in }, onActivity: { _ in })
		let second = try JSONValue.parse(t.requestBodies[1])
		let result = second["messages"]?.arrayValue?.last?["content"]?[0]
		#expect(result?["content"]?[0]?["text"]?.stringValue == "ERROR: Invalid regex: a(b")
		#expect(result?["is_error"]?.boolValue == true)
	}
}

@Suite struct ResearcherTests {
	@Test func serverToolActivityAndCitedSourcesFormTheResult() async throws {
		let brief = "## Summary\nJoins combine rows. [Postgres docs](https://www.postgresql.org/docs/joins.html) and [again](https://www.postgresql.org/docs/joins.html)"
		let (m, t) = model([
			sse([
				.serverToolUse(id: "srv1", name: "web_search", json: #"{"query":"sql joins"}"#),
				.raw(["type": "web_search_tool_result", "tool_use_id": "srv1", "content": [["type": "web_search_result", "url": "https://a.example/x", "title": "A"]]]),
				.serverToolUse(id: "srv2", name: "web_fetch", json: #"{"url":"https://www.postgresql.org/docs/joins.html"}"#),
				.text(brief),
			]),
		])
		let c = Collected()
		let r = await runResearcher(question: "How do joins work?", context: "a lesson on SQL", model: m, onUsage: c.usage, onActivity: c.line)
		#expect(r.brief == brief)
		#expect(r.sources == [ResearchSource(title: "Postgres docs", url: "https://www.postgresql.org/docs/joins.html")])
		#expect(c.lines == ["researching", "web_search: \"sql joins\"", "web_fetch: www.postgresql.org"])
		let req = try JSONValue.parse(t.requestBodies[0])
		#expect(req["messages"]?[0]?["content"]?[0]?["text"]?.stringValue == "Research question: How do joins work?\n\nContext (what this is needed for): a lesson on SQL\n\nProduce your final brief in the required format.")
		let tools = try #require(req["tools"]?.arrayValue)
		#expect(tools.contains { $0["type"]?.stringValue == "web_search_20260209" && $0["max_uses"]?.intValue == 8 })
		#expect(tools.contains { $0["type"]?.stringValue == "web_fetch_20260209" })
	}

	@Test func withoutCitedLinksTheSeenResultsAreTheSources() {
		let msg = Message(id: "a", timestamp: 0, body: .assistant(AssistantBody(content: [
			Block(raw: ["type": "web_search_tool_result", "content": [["url": "https://a.example", "title": "A"], ["url": "https://b.example", "title": "B"]]]),
		], model: "m", stopReason: "end_turn")))
		#expect(parseSources("no links", fetched: fetchedSources([msg])).map(\.url) == ["https://a.example", "https://b.example"])
	}

	@Test func aProviderErrorIsAResearchFailure() async throws {
		let (m, _) = model([.http(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"bad"}}"#)])
		let r = await runResearcher(question: "q", context: nil, model: m, onUsage: { _ in }, onActivity: { _ in })
		#expect(r.brief.hasPrefix("Research failed: "))
		#expect(isSubagentFailure(.research(r)))
	}
}
