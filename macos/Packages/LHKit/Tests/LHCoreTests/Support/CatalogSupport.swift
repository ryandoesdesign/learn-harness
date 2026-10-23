import Foundation
import LHResources
@testable import LHCore

/// The bundled native catalog (models.json via LHResources).
enum TestCatalog {
	static let shared: ModelCatalog = {
		do { return try ModelCatalog(data: LHResources.modelsJSON) } catch { fatalError("models.json: \(error)") }
	}()
}

extension CallUsage {
	/// JSON with nil fields omitted (the TS dumps drop undefined).
	var json: JSONValue {
		var o = JSONObject()
		if let inputTokens { o["inputTokens"] = .number(inputTokens) }
		if let outputTokens { o["outputTokens"] = .number(outputTokens) }
		if let cacheReadTokens { o["cacheReadTokens"] = .number(cacheReadTokens) }
		if let cacheWriteTokens { o["cacheWriteTokens"] = .number(cacheWriteTokens) }
		if let reasoningTokens { o["reasoningTokens"] = .number(reasoningTokens) }
		return .object(o)
	}
}

extension Optional where Wrapped == Double {
	var json: JSONValue { map { .number($0) } ?? .null }
}
