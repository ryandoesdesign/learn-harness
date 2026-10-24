import Foundation
import Testing
@testable import LHAgent
@testable import LHCore
import LHStore

// Port of tests/compaction-service.test.ts over an injected summarizer.

private func bigRecord(_ db: AppDatabase, turns: Int = 40) throws -> String {
	let chat = try ChatRepository(db).createChat(title: "long")
	var ms: [Message] = []
	for i in 0..<turns {
		ms.append(newUserMessage(String(repeating: "question \(i) ", count: 400), id: "u\(i)", now: i))
		ms.append(Message(id: "a\(i)", timestamp: i, body: .assistant(AssistantBody(content: [.text(String(repeating: "answer \(i) ", count: 400))], model: "claude-opus-5-5", stopReason: "end_turn"))))
	}
	try ChatRepository(db).append(ms, to: chat.id)
	return chat.id
}

private let spec = EffectiveModelSpec(model: "claude-opus-5-5", effort: .low)

@Suite(.serialized) struct CompactionServiceTests {
	@Test func overThresholdAppendsTheMarkerLogsUsageAndNotifies() async throws {
		let db = try AppDatabase.inMemory()
		let id = try bigRecord(db)
		let notes = Box<[Bool]>([])
		let calls = Box(0)
		let s = CompactionService(database: db, summarize: { _, _ in
			calls.mutate { $0 += 1 }
			return ("The learner has joins down.", [UsageStepRecord(model: "claude-opus-5-5", usage: CallUsage(inputTokens: 100, outputTokens: 20), fallbackFrom: nil)])
		}, notify: { _, running in notes.mutate { $0.append(running) } })
		await s.ensureCompacted(id, deps: .init(spec: spec, kind: .teach, thresholdTokens: 10_000, systemPromptTokens: 100))
		let r = try #require(try ChatRepository(db).get(id))
		let marker = try #require(r.messages.last?.marker)
		#expect(marker.kind == .compaction)
		#expect(marker.content.hasPrefix(COMPACTED_HISTORY_HEADER))
		#expect(r.turns?.last?.messageId == r.messages.last?.id)
		#expect(notes.value == [true, false])
		#expect(calls.value == 1)
	}

	@Test func underThresholdIsANoOp() async throws {
		let db = try AppDatabase.inMemory()
		let id = try bigRecord(db, turns: 2)
		let calls = Box(0)
		let s = CompactionService(database: db, summarize: { _, _ in calls.mutate { $0 += 1 }; return ("x", []) })
		await s.ensureCompacted(id, deps: .init(spec: spec, kind: .teach, thresholdTokens: 1_000_000, systemPromptTokens: 0))
		#expect(calls.value == 0)
		#expect(try ChatRepository(db).get(id)?.messages.last?.marker == nil)
	}

	@Test func theMutexRunsOneSummaryForConcurrentGates() async throws {
		let db = try AppDatabase.inMemory()
		let id = try bigRecord(db)
		let calls = Box(0)
		let s = CompactionService(database: db, summarize: { _, _ in
			calls.mutate { $0 += 1 }
			try await Task.sleep(for: .milliseconds(50))
			return ("summary", [])
		})
		let deps = CompactionService.Deps(spec: spec, kind: .teach, thresholdTokens: 10_000, systemPromptTokens: 0)
		async let a: Void = s.ensureCompacted(id, deps: deps)
		async let b: Void = s.ensureCompacted(id, deps: deps)
		_ = await (a, b)
		#expect(calls.value == 1)
	}

	@Test func aChainedCompactionCarriesThePriorSummary() async throws {
		let db = try AppDatabase.inMemory()
		let id = try bigRecord(db)
		let prompts = Box<[String]>([])
		let s = CompactionService(database: db, summarize: { p, _ in prompts.mutate { $0.append(p) }; return ("FIRST SUMMARY", []) })
		let deps = CompactionService.Deps(spec: spec, kind: .teach, thresholdTokens: 10_000, systemPromptTokens: 0)
		await s.ensureCompacted(id, deps: deps)
		var more: [Message] = []
		for i in 40..<80 {
			more.append(newUserMessage(String(repeating: "question \(i) ", count: 400), id: "u\(i)", now: i))
			more.append(Message(id: "a\(i)", timestamp: i, body: .assistant(AssistantBody(content: [.text(String(repeating: "answer \(i) ", count: 400))], model: "claude-opus-5-5", stopReason: "end_turn"))))
		}
		try ChatRepository(db).append(more, to: id)
		await s.ensureCompacted(id, deps: deps)
		#expect(prompts.value.count == 2)
		#expect(prompts.value[1].contains("[SYSTEM NOTE — prior compaction summary, still authoritative where not superseded]"))
		#expect(prompts.value[1].contains("FIRST SUMMARY"))
	}

	@Test func effectiveThreshold() {
		#expect(CompactionService.effectiveThreshold(setting: nil, contextWindow: 1_000_000) == 150_000)
		#expect(CompactionService.effectiveThreshold(setting: 150_000, contextWindow: 128_000) == 128_000 - 16_384)
		#expect(CompactionService.effectiveThreshold(setting: 60_000, contextWindow: nil) == 60_000)
	}

	@Test func aSummarizerFailureLeavesTheRecordUntouched() async throws {
		let db = try AppDatabase.inMemory()
		let id = try bigRecord(db)
		let before = try ChatRepository(db).get(id)?.messages.count
		struct Boom: Error {}
		let s = CompactionService(database: db, summarize: { _, _ in throw Boom() })
		await s.ensureCompacted(id, deps: .init(spec: spec, kind: .teach, thresholdTokens: 10_000, systemPromptTokens: 0))
		#expect(try ChatRepository(db).get(id)?.messages.count == before)
		#expect(await !s.isRunning(id), "the gate re-arms")
	}

	@Test func theKickIsFireAndForgetAndOverThresholdOnly() async throws {
		let db = try AppDatabase.inMemory()
		let id = try bigRecord(db)
		let s = CompactionService(database: db, summarize: { _, _ in try await Task.sleep(for: .milliseconds(30)); return ("s", []) })
		await s.kick(id, deps: .init(spec: spec, kind: .teach, thresholdTokens: 10_000, systemPromptTokens: 0))
		#expect(await s.isRunning(id))
		await s.ensureCompacted(id, deps: .init(spec: spec, kind: .teach, thresholdTokens: 10_000, systemPromptTokens: 0))
		#expect(try ChatRepository(db).get(id)?.messages.last?.marker?.kind == .compaction)
	}
}
