import Foundation

// The model catalog (docs/native-macos-m1.md, "models.json"): the price and
// context-limit registry, decoded from models.json bytes so LHCore stays
// resource-free. The caller passes `LHResources.modelsJSON`. A model
// missing from the catalog is legal everywhere: it is unpriced (cost
// renders "—", never zero) and has no context window.

/// Per-1M-token USD rates.
public struct PriceRates: Sendable, Hashable, Codable {
	public var input: Double
	public var output: Double
	public var cacheRead: Double?
	/// The 5-minute cache-write rate.
	public var cacheWrite: Double?
	/// The 1-hour cache-write rate (2× input on every current model).
	public var cacheWrite1h: Double?
	public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil, cacheWrite1h: Double? = nil) {
		self.input = input
		self.output = output
		self.cacheRead = cacheRead
		self.cacheWrite = cacheWrite
		self.cacheWrite1h = cacheWrite1h
	}
}

/// A long-context price tier: a call whose input exceeds `inputTokensAbove`
/// bills every token class at these rates.
public struct PriceTier: Sendable, Hashable, Codable {
	public var inputTokensAbove: Int
	public var input: Double
	public var output: Double
	public var cacheRead: Double?
	public var cacheWrite: Double?
	public var cacheWrite1h: Double?
	public init(inputTokensAbove: Int, input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil, cacheWrite1h: Double? = nil) {
		self.inputTokensAbove = inputTokensAbove
		self.input = input
		self.output = output
		self.cacheRead = cacheRead
		self.cacheWrite = cacheWrite
		self.cacheWrite1h = cacheWrite1h
	}

	public var rates: PriceRates { PriceRates(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, cacheWrite1h: cacheWrite1h) }
}

/// One model's price: base rates plus optional input-size tiers.
public struct ModelPrice: Sendable, Hashable, Codable {
	public var input: Double
	public var output: Double
	public var cacheRead: Double?
	public var cacheWrite: Double?
	public var cacheWrite1h: Double?
	/// USD per 1,000 web searches (server tool); nil = not billed.
	public var webSearchPer1k: Double?
	public var tiers: [PriceTier]?
	public init(input: Double, output: Double, cacheRead: Double? = nil, cacheWrite: Double? = nil, cacheWrite1h: Double? = nil, webSearchPer1k: Double? = nil, tiers: [PriceTier]? = nil) {
		self.input = input
		self.output = output
		self.cacheRead = cacheRead
		self.cacheWrite = cacheWrite
		self.cacheWrite1h = cacheWrite1h
		self.webSearchPer1k = webSearchPer1k
		self.tiers = tiers
	}

	/// The rates a call with `inputTokens` of total prompt (uncached input +
	/// cache reads + cache writes) bills at: the highest tier whose threshold
	/// it exceeds, else the base rates.
	public func rates(inputTokens: Int) -> PriceRates {
		let tier = (tiers ?? [])
			.filter { inputTokens > $0.inputTokensAbove }
			.max { $0.inputTokensAbove < $1.inputTokensAbove }
		return tier?.rates ?? PriceRates(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, cacheWrite1h: cacheWrite1h)
	}
}

/// One catalog entry.
public struct CatalogModel: Sendable, Hashable, Codable {
	public var id: String
	public var name: String
	public var contextWindow: Int
	public var maxTokens: Int
	/// Input modalities ("text", "image").
	public var input: [String]
	/// The supported effort levels (the clamp's targets).
	public var efforts: [Effort]
	public var price: ModelPrice
	public init(id: String, name: String, contextWindow: Int, maxTokens: Int, input: [String], efforts: [Effort], price: ModelPrice) {
		self.id = id
		self.name = name
		self.contextWindow = contextWindow
		self.maxTokens = maxTokens
		self.input = input
		self.efforts = efforts
		self.price = price
	}
}

/// The decoded models.json.
public struct ModelCatalog: Sendable, Hashable {
	public let version: Int
	/// Catalog order (the picker's order).
	public let models: [CatalogModel]
	private let byId: [String: CatalogModel]

	public init(version: Int = 1, models: [CatalogModel]) {
		self.version = version
		self.models = models
		var byId: [String: CatalogModel] = [:]
		for m in models where byId[m.id] == nil { byId[m.id] = m }
		self.byId = byId
	}

	/// Decode models.json bytes (`LHResources.modelsJSON`).
	public init(data: Data) throws {
		struct File: Decodable {
			var version: Int
			var models: [CatalogModel]
		}
		let file = try JSONDecoder().decode(File.self, from: data)
		self.init(version: file.version, models: file.models)
	}

	public func model(_ id: String) -> CatalogModel? { byId[id] }

	/// nil = unpriced.
	public func price(_ id: String) -> ModelPrice? { byId[id]?.price }

	/// nil = no known window (the meter renders usage-only).
	public func contextWindow(_ id: String) -> Int? { byId[id]?.contextWindow }
}
