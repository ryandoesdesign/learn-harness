import Foundation
import Testing
import LHAnthropic
@testable import LHAgent
@testable import LHCore

/// Replays the real Opus 5.5 streams recorded by LiveSmokeTests
/// (LH_RECORD=1): two turns, parallel tool calls, cache reads.
@Suite struct RecordedReplayTests {
	@Test func theRecordedLiveSessionReplaysDeterministically() async throws {
		let dir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
		let t = try ScriptedTransport(fixtures: ["live-1", "live-2", "live-3", "live-4"], in: dir)
		let l = loop(t, tools: [LiveSmokeTests.Time()])
		let t1 = await l.run(history: [], inputs: [newUserMessage("What time is it in Paris and Tokyo right now?", id: "u1", now: 1)]) { _ in }
		#expect(t1.newMessages.map(\.role) == [.user, .assistant, .toolResult, .toolResult, .assistant])
		#expect(t1.newMessages[1].assistant?.toolUses.map { $0.input["timezone"] } == ["Europe/Paris", "Asia/Tokyo"])
		#expect(t1.steps.map { $0.usage.cacheReadTokens } == [0, 545])
		let t2 = await l.run(history: t1.newMessages, inputs: [newUserMessage("Thanks. And in New York?", id: "u2", now: 1)]) { _ in }
		#expect((t2.steps.first?.usage.cacheReadTokens ?? 0) > 0)
		#expect(t2.newMessages.last?.assistant?.stopReason == "end_turn")
		// Every request's messages extend the previous request's unchanged.
		let bodies = try t.requestBodies.map { try JSONValue.parse($0)["messages"]!.arrayValue! }
		for (a, b) in zip(bodies, bodies.dropFirst()) { #expect(Array(b.prefix(a.count)) == a) }
	}
}
