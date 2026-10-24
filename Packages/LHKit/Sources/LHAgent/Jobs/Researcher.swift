import Foundation
import LHAnthropic
import LHCore
import LHResources

// The researcher (docs/native-macos-m6.md): researcher.ts rewritten for the
// Anthropic web_search / web_fetch SERVER tools — they run inside the API
// call, so activity lines come from the streamed `server_tool_use` blocks
// and the source fallback from the result blocks.

/// runner.ts runResearchJob + researcher.ts: 12 turns, web_search capped at
/// 8 uses per call, the brief in the required format.
public func runResearcher(question rawQuestion: String, context rawContext: String?, model: SubagentModel,
	onUsage: @escaping @Sendable ([UsageStepRecord]) -> Void, onActivity: @escaping @Sendable (String) -> Void) async -> ResearchResult
{
	let question = rawQuestion.jsTrimmed.isEmpty ? "(no question)" : rawQuestion
	let context = rawContext.flatMap { $0.jsTrimmed.isEmpty ? nil : $0 }
	let prompt = ([
		"Research question: \(question)",
		context.map { "Context (what this is needed for): \($0)" },
		"Produce your final brief in the required format.",
	].compactMap { $0 }).joined(separator: "\n\n")

	var config = model.config(system: LHResources.promptSegment("subagents/researcher.md") ?? "", maxTurns: 12)
	config.serverTools = [.webSearch(maxUses: 8), .webFetch()]
	let loop = AgentLoop(client: model.client, config: config)
	let seen = SeenServerCalls()
	onActivity("researching")
	let outcome = await loop.run(history: [], inputs: [newUserMessage(prompt)]) { event in
		switch event {
		case .messageUpdate(let m), .messageEnd(let m):
			for line in seen.newActivity(m) { onActivity(line) }
		default:
			break
		}
	}
	onUsage(outcome.steps)
	if outcome.aborted { return ResearchResult(brief: "Research failed: aborted", sources: []) }
	let assistants = outcome.newMessages.compactMap { m in m.assistant.map { (m, $0) } }
	if let (_, last) = assistants.last, last.stopReason == "error" {
		return ResearchResult(brief: "Research failed: \(last.errorMessage ?? "the model call failed")", sources: [])
	}
	let brief = assistants.last.map { assistantText($0.0) } ?? ""
	guard !brief.isEmpty else { return ResearchResult(brief: "Research failed: the researcher produced no text", sources: []) }
	return ResearchResult(brief: brief, sources: parseSources(brief, fetched: fetchedSources(outcome.newMessages)))
}

/// Activity lines for server tool calls not seen before: `web_search: "q"` / `web_fetch: host`.
final class SeenServerCalls: @unchecked Sendable {
	private let lock = NSLock()
	private var ids = Set<String>()

	func newActivity(_ m: Message) -> [String] {
		guard let blocks = m.assistant?.content else { return [] }
		return lock.withLock {
			blocks.compactMap { b -> String? in
				guard b.type == "server_tool_use", let id = b.raw["id"]?.stringValue, let name = b.raw["name"]?.stringValue else { return nil }
				let input = b.raw["input"]
				// Streaming input arrives empty first; report once the argument exists.
				if name == "web_search" {
					guard let q = input?["query"]?.stringValue, !q.isEmpty, ids.insert(id).inserted else { return nil }
					return "web_search: \"\(q)\""
				}
				if name == "web_fetch" {
					guard let url = input?["url"]?.stringValue, !url.isEmpty, ids.insert(id).inserted else { return nil }
					return "web_fetch: \(hostOf(url))"
				}
				return nil
			}
		}
	}
}

func hostOf(_ url: String?) -> String {
	guard let url else { return "(no url)" }
	return URL(string: url)?.host ?? url.jsSlice(0, 40)
}

/// Sources the researcher actually saw: fetched pages, then search results.
func fetchedSources(_ messages: [Message]) -> [ResearchSource] {
	var out: [ResearchSource] = []
	for m in messages {
		for b in m.assistant?.content ?? [] {
			switch b.type {
			case "web_fetch_tool_result":
				if let url = b.raw["content"]?["url"]?.stringValue {
					out.append(ResearchSource(title: b.raw["content"]?["content"]?["title"]?.stringValue ?? url, url: url))
				}
			case "web_search_tool_result":
				for r in b.raw["content"]?.arrayValue ?? [] {
					if let url = r["url"]?.stringValue { out.append(ResearchSource(title: r["title"]?.stringValue ?? url, url: url)) }
				}
			default:
				break
			}
		}
	}
	return out
}

/// runner.ts parseSources: markdown links cited in the brief, else the
/// sources seen (deduped, at most 10).
func parseSources(_ brief: String, fetched: [ResearchSource]) -> [ResearchSource] {
	var out: [ResearchSource] = []
	var seen = Set<String>()
	for m in brief.matches(of: /\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/) {
		let title = String(m.1).jsTrimmed, url = String(m.2)
		if title.isEmpty || seen.contains(url) { continue }
		seen.insert(url)
		out.append(ResearchSource(title: title, url: url))
	}
	if out.isEmpty {
		for s in fetched where !seen.contains(s.url) {
			seen.insert(s.url)
			out.append(s)
		}
	}
	return Array(out.prefix(10))
}
