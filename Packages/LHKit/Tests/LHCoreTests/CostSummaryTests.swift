import Foundation
import Testing
@testable import LHCore

// Port of tests/cost-summary.test.ts. The fixture's priced model is a
// native catalog model (the TS used an OpenRouter id from the old table).

private let catalog = TestCatalog.shared
private let PRICED = "claude-sonnet-5-5"

private func step(_ input: Int, _ output: Int) -> CallUsage {
	CallUsage(inputTokens: input, outputTokens: output, cacheReadTokens: 0, cacheWriteTokens: nil, reasoningTokens: 0)
}

private func extractionRun(_ startedAt: Int, _ extractorModel: String, _ auditorModel: String, stats: EmissionStats? = nil) -> ExtractionRunUsage {
	ExtractionRunUsage(
		startedAt: startedAt,
		at: "1970-01-01T00:00:00.\(startedAt)Z",
		durationMs: 10_000,
		stats: stats,
		stages: .init(
			extractor: ExtractionStageUsage(model: extractorModel, steps: [step(1000, 200)]),
			auditor: ExtractionStageUsage(model: auditorModel, steps: [step(2000, 100)])))
}

@Suite struct GraphCostSummaryTests {
	@Test func fixtureModelIsPriced() {
		#expect(catalog.price(PRICED) != nil)
	}

	@Test func foldsBothChannels() throws {
		let s = graphCostSummary(CostSummaryInput(
			chats: [.init(title: "Testing session", extractions: [extractionRun(100, PRICED, PRICED)])],
			sources: [.init(filePath: "/vault/modal.md", extractions: [extractionRun(200, PRICED, PRICED)])]), catalog: catalog)
		let extStep = try #require(callCost(step(1000, 200), model: PRICED, catalog: catalog))
		let audStep = try #require(callCost(step(2000, 100), model: PRICED, catalog: catalog))
		#expect(s.stages.extraction.dollars == extStep * 2)
		#expect(s.stages.audit.dollars == audStep * 2)
		#expect(s.stages.extraction.runs == 2)
		#expect(s.stages.extraction.tokens.inputTokens == 2000)
		#expect(s.stages.audit.tokens.outputTokens == 200)
		#expect(s.totalDollars == extStep * 2 + audStep * 2)
		#expect(s.runs.map(\.title) == ["/vault/modal.md", "Testing session"])
		#expect(s.runs.map(\.kind) == ["extraction", "extraction"])
		#expect(s.unpricedRuns == 0)
	}

	@Test func unpricedModelsExcludedButCountedRunNilOnlyWhenBothStagesUnpriced() {
		let s = graphCostSummary(CostSummaryInput(
			chats: [.init(title: "partial", extractions: [extractionRun(100, PRICED, "unknown-model")])],
			sources: [.init(filePath: "/vault/x.md", extractions: [extractionRun(200, "unknown-model", "unknown-model")])]), catalog: catalog)
		#expect(s.stages.audit.unpricedRuns == 2)
		#expect(s.stages.audit.dollars == 0)
		#expect(s.stages.extraction.unpricedRuns == 1)
		#expect(s.runs[0].dollars == nil)
		#expect(s.runs[1].dollars != nil)
		#expect(s.unpricedRuns == 1)
	}

	@Test func recentRunsCapNewestSurvive() {
		let s = graphCostSummary(CostSummaryInput(
			chats: [.init(title: "chat", extractions: [1, 2, 3, 4].map { extractionRun($0 * 100, PRICED, PRICED) })],
			sources: [],
			recentCap: 2), catalog: catalog)
		#expect(s.runs.map(\.startedAt) == [400, 300])
		#expect(s.stages.extraction.runs == 4, "the cap is presentational")
	}

	@Test func failedRunsCarryNoMergedStatsEmptyInputFoldsToZero() {
		let s = graphCostSummary(CostSummaryInput(chats: [.init(title: "failed", extractions: [extractionRun(100, PRICED, PRICED)])], sources: []), catalog: catalog)
		#expect(s.runs[0].merged == nil)
		let withStats = graphCostSummary(CostSummaryInput(chats: [.init(title: "ok", extractions: [extractionRun(100, PRICED, PRICED, stats: EmissionStats(nodes: 3, chains: 1))])], sources: []), catalog: catalog)
		#expect(withStats.runs[0].merged == EmissionStats(nodes: 3, chains: 1))
		let empty = graphCostSummary(CostSummaryInput(chats: [], sources: []), catalog: catalog)
		#expect(empty.totalDollars == 0)
		#expect(empty.runs.isEmpty)
		#expect(empty.stages.extraction.tokens.inputTokens == nil)
	}

	@Test func equalStartTimesKeepInputOrder() {
		let s = graphCostSummary(CostSummaryInput(
			chats: [.init(title: "a", extractions: [extractionRun(5, PRICED, PRICED)]), .init(title: "b", extractions: [extractionRun(5, PRICED, PRICED)])],
			sources: [.init(filePath: "c", extractions: [extractionRun(5, PRICED, PRICED)])]), catalog: catalog)
		#expect(s.runs.map(\.title) == ["a", "b", "c"])
	}
}
