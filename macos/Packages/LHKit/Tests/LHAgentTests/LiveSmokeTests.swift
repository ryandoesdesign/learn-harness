import Foundation
import Testing
import LHAnthropic
@testable import LHAgent
@testable import LHCore

/// The M3 live acceptance (docs/native-macos-m3.md): opt-in only —
/// `LH_LIVE=1 ANTHROPIC_API_KEY=… swift test --filter LiveSmoke`. With
/// `LH_RECORD=1` the streams are saved as `.sse` fixtures. Never runs in CI.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LH_LIVE"] == "1"))
struct LiveSmokeTests {
	struct Time: AgentTool {
		let name = "get_current_time"
		let description = "Get the current local time in an IANA timezone (for example Europe/Paris)."
		let schema = JSONSchema.object(["timezone": .string(description: "An IANA timezone name, e.g. America/New_York")], additionalProperties: false)
		func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
			guard let zone = TimeZone(identifier: input["timezone"]?.stringValue ?? "") else { return .error("Unknown timezone") }
			let f = DateFormatter()
			f.timeZone = zone
			f.dateFormat = "HH:mm zzz"
			return .value(.string(f.string(from: Date())))
		}
	}

	@Test func opusStreamsCallsTheToolAndTheSecondTurnReadsTheCache() async throws {
		let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
		let fixtures = Repo.root.appending(path: "macos/Packages/LHKit/Tests/LHAgentTests/Fixtures")
		let n = Box(0)
		let transport = RecordingTransport(URLSessionTransport(), directory: fixtures) { n.mutate { $0 += 1 }; return "live-\(n.value)" }
		let client = MessagesClient(transport: transport, apiKey: { key })
		let system = """
			You are the LearnHarness API playground: a short, friendly assistant used to check the native app's \
			Anthropic client end to end. Answer in a few sentences. When the user asks about the time anywhere, \
			call get_current_time with an IANA timezone name and report the result in plain words. Call the tool \
			in parallel for several places. Never invent a time without calling the tool.
			"""
		let loop = AgentLoop(client: client, config: AgentConfig(model: "claude-opus-5-5", effort: .low, system: system, tools: [Time()], thinkingDisplay: .summarized, cacheTTL: .oneHour))
		let transforms = Box<[JSONValue]>([])
		let updates = Box(0)
		let t1 = await loop.run(history: [], inputs: [newUserMessage("What time is it in Paris and Tokyo right now?")]) { e in
			if case .messageUpdate = e { updates.mutate { $0 += 1 } }
			if case .inputTransformations(let t) = e { transforms.mutate { $0 += t } }
		}
		let history = t1.newMessages
		for (i, s) in t1.steps.enumerated() { print("TURN1 call \(i + 1): \(s.model) in=\(s.usage.inputTokens ?? -1) read=\(s.usage.cacheReadTokens ?? -1) write=\(s.usage.cacheWriteTokens ?? -1) (1h \(s.usage.cacheWrite1hTokens ?? -1)) out=\(s.usage.outputTokens ?? -1)") }
		print("TURN1 roles:", history.map(\.role.rawValue), "stop:", history.compactMap(\.assistant).map(\.stopReason), "errors:", history.compactMap(\.assistant).compactMap(\.errorMessage))
		#expect(history.contains { $0.assistant?.toolUses.contains { $0.name == "get_current_time" } == true })
		#expect(history.last?.assistant?.stopReason == "end_turn")
		#expect(updates.value > 1, "streamed")

		let t2 = await loop.run(history: history, inputs: [newUserMessage("Thanks. And in New York?")]) { e in
			if case .inputTransformations(let t) = e { transforms.mutate { $0 += t } }
		}
		for (i, s) in t2.steps.enumerated() { print("TURN2 call \(i + 1): \(s.model) in=\(s.usage.inputTokens ?? -1) read=\(s.usage.cacheReadTokens ?? -1) write=\(s.usage.cacheWriteTokens ?? -1) (1h \(s.usage.cacheWrite1hTokens ?? -1)) out=\(s.usage.outputTokens ?? -1)") }
		print("TURN2 stop:", t2.newMessages.compactMap(\.assistant).map(\.stopReason), "errors:", t2.newMessages.compactMap(\.assistant).compactMap(\.errorMessage))
		print("input_transformations:", JSONValue.array(transforms.value).serialized())
		#expect((t2.steps.first?.usage.cacheReadTokens ?? 0) > 0, "turn 2 reads the cache")
		#expect(t2.newMessages.last?.assistant?.stopReason == "end_turn")
		#expect(transforms.value.isEmpty, "no thinking blocks dropped or flagged")
	}
}
