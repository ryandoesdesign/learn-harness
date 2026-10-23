import Foundation

// Port of src/core/prices.ts's pure folds. Usage is CAPTURED in the records;
// cost is INFERRED here at read time from the catalog — nothing stores
// dollars, so a price correction re-prices the whole history for free.

/// Sum per-step usages into one CallUsage. A field stays nil when EVERY
/// step left it unreported — absent is not zero.
public func sumSteps(_ steps: [CallUsage]) -> CallUsage {
	func sumIfAny(_ values: [Int?]) -> Int? {
		values.allSatisfy { $0 == nil } ? nil : values.reduce(0) { $0 + ($1 ?? 0) }
	}
	return CallUsage(
		inputTokens: sumIfAny(steps.map(\.inputTokens)),
		outputTokens: sumIfAny(steps.map(\.outputTokens)),
		cacheReadTokens: sumIfAny(steps.map(\.cacheReadTokens)),
		cacheWriteTokens: sumIfAny(steps.map(\.cacheWriteTokens)),
		reasoningTokens: sumIfAny(steps.map(\.reasoningTokens)))
}

/// One model call's inferred cost in USD — nil when the model is unpriced
/// or input/output are absent (never guess a price). Cached input bills at
/// the cache-read rate; cache writes bill separately where priced. A call
/// whose input exceeds a tier's threshold bills at that tier's rates.
public func callCost(_ usage: CallUsage, model: String, catalog: ModelCatalog) -> Double? {
	guard let price = catalog.price(model), let inputTokens = usage.inputTokens, let outputTokens = usage.outputTokens else { return nil }
	let rates = price.rates(inputTokens: inputTokens)
	let cacheRead = Double(usage.cacheReadTokens ?? 0)
	let freshInput = Swift.max(0, Double(inputTokens) - cacheRead)
	let cacheWriteCost = Double(usage.cacheWriteTokens ?? 0) / 1e6 * (rates.cacheWrite ?? 0)
	return (freshInput / 1e6) * rates.input
		+ (cacheRead / 1e6) * (rates.cacheRead ?? rates.input)
		+ (Double(outputTokens) / 1e6) * rates.output
		+ cacheWriteCost
}

/// One turn's inferred cost — the sum over its steps; nil when unpriceable.
public func turnCost(_ turn: TurnUsage, catalog: ModelCatalog) -> Double? {
	var total = 0.0
	for step in turn.steps {
		guard let c = callCost(step, model: turn.model, catalog: catalog) else { return nil }
		total += c
	}
	return total
}

/// A session's total inferred cost. Unpriceable turns don't poison the
/// total — they are counted in `unpriced` so the UI can say so.
public struct SessionCost: Sendable, Hashable {
	public var cost: Double
	public var unpriced: Int
	public init(cost: Double, unpriced: Int) {
		self.cost = cost
		self.unpriced = unpriced
	}
}

public func sessionCost(_ turns: [TurnUsage]?, catalog: ModelCatalog) -> SessionCost {
	var out = SessionCost(cost: 0, unpriced: 0)
	for turn in turns ?? [] {
		if let c = turnCost(turn, catalog: catalog) { out.cost += c } else { out.unpriced += 1 }
	}
	return out
}

public func sessionCost(_ record: ChatRecord, catalog: ModelCatalog) -> SessionCost {
	sessionCost(record.turns, catalog: catalog)
}

/// The session's context-window footprint.
public struct ContextWindowReading: Sendable, Hashable {
	public var model: String
	public var usedTokens: Int
	/// nil when the model is not in the catalog (render usage-only).
	public var limit: Int?
	public init(model: String, usedTokens: Int, limit: Int?) {
		self.model = model
		self.usedTokens = usedTokens
		self.limit = limit
	}
}

/// The LAST model call's footprint (input + output + both cache
/// directions) against the model's catalog window. A zeroed last step (an
/// abort artifact) is not a reading: fall back to the previous step. nil
/// when the record has no usage yet.
public func contextWindow(_ turns: [TurnUsage]?, catalog: ModelCatalog) -> ContextWindowReading? {
	guard let last = turns?.last else { return nil }
	let limit = catalog.contextWindow(last.model)
	for step in last.steps.reversed() {
		let footprint = stepFootprint(step)
		if footprint == 0 { continue }
		return ContextWindowReading(model: last.model, usedTokens: footprint, limit: limit)
	}
	return nil
}

public func contextWindow(_ record: ChatRecord, catalog: ModelCatalog) -> ContextWindowReading? {
	contextWindow(record.turns, catalog: catalog)
}

private func stepFootprint(_ step: CallUsage) -> Int {
	(step.inputTokens ?? 0) + (step.outputTokens ?? 0) + (step.cacheReadTokens ?? 0) + (step.cacheWriteTokens ?? 0)
}

/// A job's inferred cost — nil until usage lands, or for unpriced models.
/// Like the TS, it prices the job's accumulated usage as one call.
public func jobCost(_ usage: JobUsage?, catalog: ModelCatalog) -> Double? {
	guard let usage else { return nil }
	return callCost(usage.callUsage, model: usage.model, catalog: catalog)
}

public func jobCost(_ job: JobRecord, catalog: ModelCatalog) -> Double? {
	jobCost(job.usage, catalog: catalog)
}
