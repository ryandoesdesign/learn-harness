import Foundation
import LHAnthropic
import LHCore
import LHResources

// Ports of agent/subagents/demo-builder.ts and visual-maker.ts. Prompts are
// bundled resources (prompts/subagents/*.md); tool texts and result wording
// are TS-identical.

// MARK: - Demo builder

/// demo-builder.ts runDemoBuilder: write_demo/run_demo in an agent loop
/// (24 turns), then the code-side gate: the delivered html must be the one
/// last tested, and that run must have passed — else a final verification.
public func runDemoBuilder(title rawTitle: String, brief rawBrief: String, model: SubagentModel, verifier: any HeadlessVerifier,
	onUsage: @escaping @Sendable ([UsageStepRecord]) -> Void, onActivity: @escaping @Sendable (String) -> Void) async -> DemoResult
{
	let title = rawTitle.jsTrimmed.isEmpty ? "Interactive demo" : rawTitle.jsTrimmed
	let brief = rawBrief.jsTrimmed.isEmpty ? "(no brief)" : rawBrief.jsTrimmed
	let state = BuilderState()
	let prompt = [
		"Demo title: \(title)",
		"Brief (all you know about the lesson — this comes from the teacher, verbatim):",
		brief,
		"",
		"Build the demo, test it with run_demo, iterate until PASSED, then finish with your notes.",
	].joined(separator: "\n")
	let tools: [any AgentTool] = [WriteDemoTool(state: state, onActivity: onActivity), RunDemoTool(state: state, verifier: verifier, onActivity: onActivity)]
	let loop = AgentLoop(client: model.client, config: model.config(system: LHResources.promptSegment("subagents/demo-builder.md") ?? "", tools: tools, maxTurns: 24))
	let outcome = await loop.run(history: [], inputs: [newUserMessage(prompt)]) { event in
		if case .toolStart(_, let name, _) = event { onActivity(name) }
	}
	onUsage(outcome.steps)
	if outcome.aborted { return DemoResult(title: title, html: "", tested: true, notes: "FAILED: aborted") }
	let last = outcome.newMessages.last { $0.assistant != nil }
	if let a = last?.assistant, a.stopReason == "error" {
		return DemoResult(title: title, html: "", tested: true, notes: "FAILED: the builder crashed — \(a.errorMessage ?? "unknown error")")
	}
	let finalText = last.map(assistantText) ?? ""
	guard let html = state.html else {
		return DemoResult(title: title, html: "", tested: true, notes: "FAILED: the builder never wrote a demo.\(finalText.isEmpty ? "" : " (\(finalText.jsSlice(0, 300)))")")
	}
	if state.testedHtml != html || state.lastResult?.ok != true {
		onActivity("final verification")
		do {
			let verify = try await verifier.runDemo(html, probe: nil)
			if !verify.ok {
				return DemoResult(title: title, html: "", tested: true, notes: "FAILED: the demo never passed headless verification (\(failureSummary(verify))).")
			}
		} catch {
			return DemoResult(title: title, html: "", tested: true, notes: "FAILED: final verification crashed — \(error)")
		}
	}
	return DemoResult(title: title, html: html, tested: true, notes: finalText.isEmpty ? nil : finalText)
}

final class BuilderState: @unchecked Sendable {
	private let lock = NSLock()
	private var _html: String?
	private var _tested: String?
	private var _last: DemoRunResult?
	var html: String? { get { lock.withLock { _html } } set { lock.withLock { _html = newValue } } }
	var testedHtml: String? { get { lock.withLock { _tested } } set { lock.withLock { _tested = newValue } } }
	var lastResult: DemoRunResult? { get { lock.withLock { _last } } set { lock.withLock { _last = newValue } } }
}

struct WriteDemoTool: AgentTool {
	let state: BuilderState
	let onActivity: @Sendable (String) -> Void
	let name = "write_demo"
	let description = "Write the complete self-contained HTML document for the demo (overwrites any previous version). Always follow with run_demo to test it headlessly."
	let schema = JSONSchema.object(["html": .string(description: "The complete HTML document: <!doctype html>…</html>, all JS inline.")])

	func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		let html = input["html"]?.stringValue ?? ""
		if html.jsTrimmed.isEmpty { return .value("ERROR: empty document — write the full HTML.") }
		state.html = html
		onActivity("write_demo: \(jsToFixed(Double(html.jsLength) / 1024, 1)) KB")
		return .value(.string("Saved (\(html.jsLength) bytes). Now call run_demo to test it — never deliver untested."))
	}
}

struct RunDemoTool: AgentTool {
	let state: BuilderState
	let verifier: any HeadlessVerifier
	let onActivity: @Sendable (String) -> Void
	let name = "run_demo"
	let description = "Headlessly execute the current demo in a browser and report console errors, uncaught errors, and failed requests. Optionally pass a probe expression to assert on page state."
	let schema = JSONSchema.object(["probe": JSONSchema.string(description: "Optional JS expression evaluated in the page after settling, e.g. \"document.querySelectorAll('input').length\".").optional()])

	func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
		guard let html = state.html else { return .value("ERROR: nothing to run — call write_demo first.") }
		let result: DemoRunResult
		do {
			result = try await verifier.runDemo(html, probe: input["probe"]?.stringValue)
		} catch {
			onActivity("run_demo: browser error")
			return .value(.string("HEADLESS ERROR (retrying may help): \(error)"))
		}
		state.testedHtml = html
		state.lastResult = result
		onActivity(result.ok ? "run_demo: clean" : "run_demo: \(summarizeCounts(result))")
		return .value(.string(formatRunResult(result)))
	}
}

func summarizeCounts(_ r: DemoRunResult) -> String {
	func n(_ c: Int, _ what: String) -> String? { c > 0 ? "\(c) \(what)\(c == 1 ? "" : "s")" : nil }
	let parts = [n(r.consoleErrors.count, "console error"), n(r.pageErrors.count, "page error"), n(r.failedRequests.count, "failed request")].compactMap { $0 }
	return parts.isEmpty ? "ok" : parts.joined(separator: ", ")
}

func formatRunResult(_ r: DemoRunResult) -> String {
	if r.ok {
		let probe = r.probeResult.map { " Probe result: \($0.serialized())." } ?? ""
		return "PASSED: no console errors, no uncaught errors, no failed requests.\(probe) If you are satisfied, finish with your notes; otherwise keep improving and re-test."
	}
	var sections = ["FAILED: \(summarizeCounts(r))."]
	func list(_ items: [String]) -> String { items.prefix(10).map { "- \($0)" }.joined(separator: "\n") }
	if !r.consoleErrors.isEmpty { sections.append("Console errors:\n\(list(r.consoleErrors))") }
	if !r.pageErrors.isEmpty { sections.append("Uncaught errors:\n\(list(r.pageErrors))") }
	if !r.failedRequests.isEmpty { sections.append("Failed requests:\n\(list(r.failedRequests))") }
	sections.append("Fix the document (write_demo) and re-test (run_demo).")
	return sections.joined(separator: "\n")
}

func failureSummary(_ r: DemoRunResult) -> String {
	let details = Array((r.consoleErrors + r.pageErrors + r.failedRequests).prefix(5))
	return details.isEmpty ? summarizeCounts(r) : "\(summarizeCounts(r)) — \(details.joined(separator: " | "))"
}

// MARK: - Visual maker

let LOOK_MESSAGE = "Here is the current render of your SVG — inspect it critically (geometry, labels, clipping, readability):"
let UNLOOKED_FINISH_MESSAGE = "You finished without looking at a render of your final SVG. Above is its render. If it is correct and clean, reply with just your notes; otherwise call write_svg with fixes and render again."

let visualDeclarations: [ToolDefinition] = [
	declaration("write_svg", "Write the complete SVG source for the figure (overwrites any previous version).",
		.object(["svg": .string(description: "Complete <svg xmlns=\"…\">…</svg> markup.")])),
	declaration("edit_svg", "Replace one exact spot in the current SVG: old_text must appear EXACTLY ONCE and is replaced by new_text. Call write_svg first. For larger changes, write_svg the whole document.",
		.object(["old_text": .string(description: "The exact text to replace — must match exactly once in the current SVG."), "new_text": .string(description: "The replacement text.")])),
	declaration("render_svg", "Render the current SVG to a PNG and show it to you for inspection. No arguments.", .object([:])),
]

/// visual-maker.ts runVisualMaker: a hand-rolled loop (8 iterations) that
/// renders, LOOKS (the PNG goes back as an image), and iterates; it never
/// finishes on an unlooked SVG.
public func runVisualMaker(brief rawBrief: String, model: SubagentModel, verifier: any HeadlessVerifier, maxIterations: Int = 8,
	onUsage: @escaping @Sendable ([UsageStepRecord]) -> Void, onActivity: @escaping @Sendable (String) -> Void) async -> VisualResult
{
	let brief = rawBrief.jsTrimmed.isEmpty ? "(no brief)" : rawBrief.jsTrimmed
	let system = LHResources.promptSegment("subagents/visual-maker.md") ?? ""
	let prompt = [
		"Brief for ONE precise figure (from the teacher, verbatim — it is everything you know):",
		brief,
		"",
		"Author the SVG, render it, look at it, iterate until correct, then finish with your notes.",
	].joined(separator: "\n")
	var messages = [newUserMessage(prompt)]
	var current: String?
	var rendered: String?
	var finalText = ""
	do {
		for _ in 0..<maxIterations {
			try Task.checkCancellation()
			let (assistant, steps) = try await subagentCall(model, system: system, declarations: visualDeclarations, context: messages)
			onUsage(steps)
			messages.append(assistant)
			let calls = assistant.assistant?.toolUses ?? []
			if calls.isEmpty {
				finalText = assistantText(assistant)
				if let svg = current, rendered != svg {
					let png: Data
					do { png = try await verifier.renderSvg(svg) } catch {
						return VisualResult(svg: "", notes: "FAILED: rendering the final SVG failed — \(error)")
					}
					onActivity("render_svg: inspecting final render")
					rendered = svg
					messages.append(imageMessage(UNLOOKED_FINISH_MESSAGE, pngs: [png]))
					continue
				}
				guard let svg = current else {
					return VisualResult(svg: "", notes: "FAILED: the maker never wrote an SVG.\(finalText.isEmpty ? "" : " (\(finalText.jsSlice(0, 300)))")")
				}
				return VisualResult(svg: svg, notes: finalText.isEmpty ? nil : finalText)
			}
			var renderPng: Data?
			for call in calls {
				func reply(_ text: String) {
					messages.append(toolResultMessage(call, text, isError: text.hasPrefix("ERROR:") || text.hasPrefix("RENDER ERROR")))
				}
				switch call.name {
				case "write_svg":
					guard let svg = call.input["svg"]?.stringValue, svg.contains("<svg") else {
						reply("ERROR: expected a complete <svg>…</svg> document in the `svg` field.")
						continue
					}
					current = svg
					onActivity("write_svg: \(jsToFixed(Double(svg.jsLength) / 1024, 1)) KB")
					reply("Saved (\(svg.jsLength) bytes). Call render_svg to look at it.")
				case "edit_svg":
					guard let svg = current else { reply("ERROR: nothing to edit — call write_svg first."); continue }
					guard let old = call.input["old_text"]?.stringValue, let new = call.input["new_text"]?.stringValue, !old.isEmpty else {
						reply("ERROR: expected old_text (non-empty) and new_text strings.")
						continue
					}
					let occurrences = svg.components(separatedBy: old).count - 1
					if occurrences == 0 {
						reply("ERROR: old_text not found. Closest line for reference:\n\(snippetAround(svg, old))")
						continue
					}
					if occurrences > 1 {
						reply("ERROR: old_text appears \(occurrences) times — it must match EXACTLY ONCE. Include more surrounding context to make it unique.")
						continue
					}
					current = svg.replacingOccurrences(of: old, with: new)
					onActivity("edit_svg: applied")
					reply("OK — replaced 1 occurrence. Call render_svg to look at the edited SVG.")
				case "render_svg":
					guard let svg = current else { reply("ERROR: nothing to render — call write_svg first."); continue }
					do {
						renderPng = try await verifier.renderSvg(svg)
						rendered = svg
						onActivity("render_svg: inspecting render")
						reply("Rendered — the PNG follows in the next message. Look at it.")
					} catch {
						onActivity("render_svg: render error")
						reply("RENDER ERROR (the SVG may be malformed): \(error). Fix it with write_svg and render again.")
					}
				default:
					reply("ERROR: unknown tool \"\(call.name)\". Use write_svg, edit_svg, or render_svg.")
				}
			}
			if let png = renderPng { messages.append(imageMessage(LOOK_MESSAGE, pngs: [png])) }
		}
	} catch is CancellationError {
		return VisualResult(svg: "", notes: "FAILED: aborted")
	} catch {
		return VisualResult(svg: "", notes: "FAILED: the maker crashed — \(error)")
	}
	if let svg = current, rendered == svg {
		return VisualResult(svg: svg, notes: finalText.isEmpty ? "Iteration limit reached — delivering the last verified SVG." : finalText)
	}
	return VisualResult(svg: "", notes: "FAILED: iteration limit (\(maxIterations)) reached without a verified SVG.")
}

/// A 3-line numbered window around the line sharing the most words with `target`.
func snippetAround(_ svg: String, _ target: String) -> String {
	let words = target.jsTrimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
	if words.isEmpty { return "(empty old_text)" }
	let lines = svg.components(separatedBy: "\n")
	var bestAt = -1, bestScore = -1
	for (i, line) in lines.enumerated() {
		let score = words.filter { line.contains($0) }.count
		if score > bestScore { bestScore = score; bestAt = i }
	}
	if bestAt < 0 { return "(no similar line found)" }
	let from = max(0, bestAt - 1), to = min(lines.count, bestAt + 2)
	return (from..<to).map { "\($0 + 1) | \(lines[$0])" }.joined(separator: "\n")
}
