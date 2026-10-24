import Foundation
import Testing
@testable import LHCore

// tests/prices-sync.test.ts's drift guard, REWRITTEN for the static native
// catalog: every catalog model has a price and a context window (there is
// no sync script to drift from). Plus the catalog-driven price folds,
// including the long-context tier the TS ignored.

private let catalog = TestCatalog.shared

@Suite struct ModelCatalogTests {
	@Test func everyCatalogModelHasAPriceAndAContextWindow() {
		#expect(!catalog.models.isEmpty)
		for m in catalog.models {
			#expect(m.price.input > 0 && m.price.output > 0, "\(m.id) priced")
			#expect(m.price.cacheRead != nil && m.price.cacheWrite != nil, "\(m.id) cache rates")
			#expect(catalog.contextWindow(m.id) == m.contextWindow)
			#expect(m.contextWindow > 0 && m.maxTokens > 0, "\(m.id) limits")
			#expect(!m.efforts.isEmpty, "\(m.id) efforts")
			#expect(catalog.price(m.id) == m.price)
		}
	}

	@Test func pinsTheFiveCurrentModels() {
		#expect(catalog.models.map(\.id) == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5", "claude-fable-5-1"])
		#expect(catalog.model("claude-fable-5")?.efforts == [.xhigh, .max])
		#expect(catalog.model("claude-fable-5-1")?.efforts == [.xhigh, .max])
		#expect(catalog.model("claude-opus-5-5")?.efforts == Effort.allCases)
		#expect(catalog.model("claude-haiku-5-5")?.price.tiers?.first?.inputTokensAbove == 100_000)
	}

	@Test func unknownModelsAreUnpricedWithNoWindow() {
		#expect(catalog.model("openrouter:x/y") == nil)
		#expect(catalog.price("openrouter:x/y") == nil)
		#expect(catalog.contextWindow("openrouter:x/y") == nil)
	}

	@Test func decodingRejectsJunk() {
		#expect(throws: (any Error).self) { try ModelCatalog(data: Data("{}".utf8)) }
	}
}

@Suite struct PriceFoldTests {
	@Test func callCostFreshInputCacheReadCacheWriteOutput() throws {
		// Opus 5.5, Anthropic-native classes: uncached 90k @ $4 + cached 10k @ $0.2
		// + 5m write 3k @ $5 + 1h write 2k @ $8 + out 20k @ $20 + 3 searches @ $10/1k.
		let c = try #require(callCost(CallUsage(inputTokens: 90_000, outputTokens: 20_000, cacheReadTokens: 10_000, cacheWriteTokens: 5_000, cacheWrite1hTokens: 2_000, webSearchRequests: 3), model: "claude-opus-5-5", catalog: catalog))
		#expect(abs(c - (0.36 + 0.002 + 0.015 + 0.016 + 0.4 + 0.03)) < 1e-12)
	}

	@Test func callCostAppliesTheTierAboveOneHundredK() throws {
		let base = try #require(callCost(CallUsage(inputTokens: 100_000, outputTokens: 1_000), model: "claude-haiku-5-5", catalog: catalog))
		#expect(abs(base - (0.01 + 0.0005)) < 1e-12, "exactly 100k is NOT above the threshold")
		// The tier keys on the whole prompt: 60k uncached + 50k read + 10k write = 120k > 100k.
		let tiered = try #require(callCost(CallUsage(inputTokens: 60_000, outputTokens: 1_000, cacheReadTokens: 50_000, cacheWriteTokens: 10_000), model: "claude-haiku-5-5", catalog: catalog))
		// Every class at tier rates: uncached 60k @ 0.5, cached 50k @ 0.05, write 10k @ 0.625, out 1k @ 2.5.
		#expect(abs(tiered - (0.03 + 0.0025 + 0.00625 + 0.0025)) < 1e-12)
		let under = try #require(callCost(CallUsage(inputTokens: 60_000, outputTokens: 0, cacheReadTokens: 30_000), model: "claude-haiku-5-5", catalog: catalog))
		#expect(abs(under - (0.006 + 0.0003)) < 1e-12, "90k prompt stays on base rates")
		// Untiered models ignore size.
		let opus = try #require(callCost(CallUsage(inputTokens: 200_000, outputTokens: 0), model: "claude-opus-5-5", catalog: catalog))
		#expect(abs(opus - 0.8) < 1e-12)
	}

	@Test func tierSelectionPicksTheHighestExceededThreshold() {
		let price = ModelPrice(input: 1, output: 1, tiers: [
			PriceTier(inputTokensAbove: 200, input: 3, output: 3),
			PriceTier(inputTokensAbove: 100, input: 2, output: 2),
		])
		#expect(price.rates(inputTokens: 100).input == 1)
		#expect(price.rates(inputTokens: 150).input == 2)
		#expect(price.rates(inputTokens: 201).input == 3)
	}

	@Test func callCostUnknownModelAndAbsentFieldsAreNil() {
		#expect(callCost(CallUsage(inputTokens: 100, outputTokens: 5), model: "not/a-model", catalog: catalog) == nil)
		#expect(callCost(CallUsage(inputTokens: 100), model: "claude-opus-5-5", catalog: catalog) == nil)
	}

	@Test func sumStepsAbsentStaysAbsent() {
		let s = sumSteps([CallUsage(inputTokens: 100, outputTokens: 20), CallUsage(inputTokens: 50, outputTokens: 10, cacheReadTokens: 30)])
		#expect(s == CallUsage(inputTokens: 150, outputTokens: 30, cacheReadTokens: 30))
		#expect(sumSteps([CallUsage(), CallUsage()]) == CallUsage())
		#expect(sumSteps([]) == CallUsage())
	}

	@Test func turnAndSessionCostCountUnpricedTurns() {
		let turn = TurnUsage(id: "t1", messageId: "m1", at: "x", model: "claude-sonnet-5-5", steps: [CallUsage(inputTokens: 10_000, outputTokens: 2_000), CallUsage(inputTokens: 12_000, outputTokens: 1_000)])
		#expect(turnCost(turn, catalog: catalog) != nil)
		let other = TurnUsage(id: "t2", messageId: "m2", at: "x", model: "openrouter:x/y", steps: [CallUsage(inputTokens: 1, outputTokens: 1)])
		let totals = sessionCost([turn, other], catalog: catalog)
		#expect(totals.unpriced == 1)
		#expect(totals.cost == turnCost(turn, catalog: catalog))
		#expect(sessionCost(nil, catalog: catalog) == SessionCost(cost: 0, unpriced: 0))
	}

	@Test func contextWindowReadsTheLimitFromTheCatalog() throws {
		let turns = [
			TurnUsage(id: "t1", messageId: "m1", at: "x", model: "claude-opus-5-5", steps: [CallUsage(inputTokens: 9_000, outputTokens: 1_000)]),
			TurnUsage(id: "t2", messageId: "m2", at: "x", model: "claude-opus-5-5", steps: [
				CallUsage(inputTokens: 40_000, outputTokens: 1_000, cacheReadTokens: 145_000, cacheWriteTokens: 4_000),
				CallUsage(inputTokens: 0, outputTokens: 0),
			]),
		]
		let cw = try #require(contextWindow(turns, catalog: catalog))
		#expect(cw == ContextWindowReading(model: "claude-opus-5-5", usedTokens: 190_000, limit: 1_000_000), "zeroed tail falls back; cache tokens count")
		#expect(contextWindow([], catalog: catalog) == nil)
		let unknown = try #require(contextWindow([TurnUsage(id: "t", messageId: "m", at: "x", model: "openrouter:x/y", steps: [CallUsage(inputTokens: 5)])], catalog: catalog))
		#expect(unknown.limit == nil, "no window, never a guessed one")
		#expect(contextWindow([TurnUsage(id: "t", messageId: "m", at: "x", model: "claude-opus-5-5", steps: [CallUsage(inputTokens: 0)])], catalog: catalog) == nil)
	}

	@Test func jobCostPricesAccumulatedUsage() {
		let usage = JobUsage(model: "claude-sonnet-5-5", inputTokens: 1_000_000, outputTokens: 100_000, steps: 3)
		#expect(jobCost(usage, catalog: catalog).map { abs($0 - 3.0) < 1e-12 } == true)
		#expect(jobCost(nil, catalog: catalog) == nil)
		#expect(jobCost(JobUsage(model: "x", inputTokens: 1, outputTokens: 1, steps: 1), catalog: catalog) == nil)
	}
}
