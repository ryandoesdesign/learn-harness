import Foundation
import Testing
@testable import LHCore

// Port of tests/fuzzy.test.ts, plus the golden corpus (Golden/cost.fuzzy.json).

@Suite struct FuzzyScoreTests {
	private func fields(_ id: String, _ name: String) -> [String] { ["openrouter", id, name] }

	@Test func matchesAcrossFieldsCaseInsensitively() {
		#expect(fuzzyScore("GLM", fields: fields("z-ai/glm-5.3-flash", "ZAI: GLM 5.3 Flash")) != nil)
		#expect(fuzzyScore("flash", fields: fields("z-ai/glm-5.3-flash", "ZAI: GLM 5.3 Flash")) != nil)
	}

	@Test func multiTokenQueriesNeedEveryTokenToMatch() {
		#expect(fuzzyScore("glm flash", fields: fields("z-ai/glm-5.3-flash", "ZAI: GLM 5.3 Flash")) != nil)
		#expect(fuzzyScore("glm qwen", fields: fields("z-ai/glm-5.3-flash", "ZAI: GLM 5.3 Flash")) == nil)
	}

	@Test func ranksExactAbovePrefixAboveBuriedSubstring() throws {
		let exact = try #require(fuzzyScore("flash", "openrouter", "flash", "other"))
		let prefix = try #require(fuzzyScore("flash", "openrouter", "flash-2", "other"))
		let buried = try #require(fuzzyScore("flash", "openrouter", "z-ai/glm-5.3-flash", "other"))
		#expect(exact > prefix && prefix > buried, "\(exact) > \(prefix) > \(buried)")
	}

	@Test func rewardsWholeQueryContiguityInASingleField() throws {
		let split = try #require(fuzzyScore("glm flash", fields: fields("z-ai/glm-5.3-flash", "x")))
		let joined = try #require(fuzzyScore("glm 5.3", fields: fields("z-ai/glm-5.3-flash", "x")))
		#expect(joined > split, "\(joined) > \(split)")
	}

	@Test func emptyQueryMatchesEverythingAtZero() {
		#expect(fuzzyScore("", "anything") == 0)
		#expect(fuzzyScore("   ", "anything") == 0)
	}
}

@Suite struct FuzzyGoldenTests {
	@Test func pairsMatchTS() throws {
		let golden = try Golden.load("cost.fuzzy")
		let pairs = try #require(golden["pairs"]?.arrayValue)
		#expect(!pairs.isEmpty)
		for row in pairs {
			let query = try #require(row["query"]?.stringValue)
			let fields = (row["fields"]?.arrayValue ?? []).compactMap(\.stringValue)
			let actual: JSONValue = fuzzyScore(query, fields: fields).map { .number($0) } ?? .null
			expectJSONEqual(actual, row["score"]!)
		}
	}

	@Test func goldenGraphNodeNamesMatchTS() throws {
		let golden = try Golden.load("cost.fuzzy")
		let nodeFields = (golden["nodeFields"]?.arrayValue ?? []).map { ($0.arrayValue ?? []).compactMap(\.stringValue) }
		#expect(nodeFields.count > 200)
		// The dump's field rows are the golden ledger's distinct nodes.
		var seen = Set<String>()
		var ledger: [[String]] = []
		for line in try Fixtures.jsonl("graph/nodes.jsonl") {
			let id = try #require(line["id"]?.stringValue)
			guard seen.insert(id).inserted else { continue }
			ledger.append([line["name"]!.stringValue!] + (line["aliases"]?.arrayValue ?? []).compactMap(\.stringValue))
		}
		#expect(ledger == nodeFields)
		for q in golden["nodeQueries"]?.arrayValue ?? [] {
			let query = try #require(q["query"]?.stringValue)
			let actual = JSONValue.array(nodeFields.map { fuzzyScore(query, fields: $0).map { .number($0) } ?? .null })
			expectJSONEqual(actual, q["scores"]!)
		}
	}
}
