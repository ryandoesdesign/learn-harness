import CryptoKit
import Foundation
import Testing
@testable import LHCore

/// Key-sorted JSON (keys by UTF-16 code unit — JS's default sort): the
/// canonical form scripts/core-golden/transcript.ts hashes.
private func canonical(_ v: JSONValue) -> String {
	switch v {
	case .array(let a):
		return "[\(a.map(canonical).joined(separator: ","))]"
	case .object(let o):
		let keys = o.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
		return "{\(keys.map { "\(JSONValue.quote($0)):\(canonical(o[$0]!))" }.joined(separator: ","))}"
	default:
		return v.serialized()
	}
}

private func sha256(_ s: String) -> String {
	SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func viewJSON(_ view: [ViewMessage]) -> JSONValue { .array(view.map(\.json)) }

/// The part skeleton the dump writes: "role:id", then type|state|id|toolCallId per part.
private func skeleton(_ view: [ViewMessage]) -> JSONValue {
	.array(view.map { m in
		.array([.string("\(m.role.rawValue):\(m.id)")] + m.parts.map { p in
			.string([p.type, p.state?.rawValue ?? "", p.id ?? "", p.toolCallId ?? ""].joined(separator: "|"))
		})
	})
}

@Suite struct TranscriptViewGoldenTests {
	@Test(arguments: [Fixtures.teachChatId, Fixtures.practiceChatId])
	func fullRecordMatchesTS(chatId: String) throws {
		let golden = try Golden.load("transcript.view.\(chatId)")
		let view = viewJSON(projectView(try Fixtures.chat(chatId).messages))
		expectJSONEqual(view, golden["full"]!)
		#expect(sha256(canonical(view)) == golden["fullSha256"]?.stringValue)
	}

	@Test(arguments: [Fixtures.teachChatId, Fixtures.practiceChatId])
	func everyPrefixMatchesTS(chatId: String) throws {
		let golden = try Golden.load("transcript.view.\(chatId)")
		let messages = try Fixtures.chat(chatId).messages
		let rows = golden["prefixes"]?.arrayValue ?? []
		#expect(rows.count == messages.count + 1)
		for row in rows {
			let n = try #require(row["n"]?.intValue)
			let prefix = Array(messages.prefix(n))
			let settled = projectView(prefix)
			expectJSONEqual(skeleton(settled), row["skeleton"]!)
			#expect(sha256(canonical(viewJSON(settled))) == row["sha256"]?.stringValue, "settled view, prefix \(n)")
			let live = LiveTurnState(inFlight: true, streamingIds: Set(prefix.last.map { [$0.id] } ?? []))
			#expect(sha256(canonical(viewJSON(projectView(prefix, live: live)))) == row["liveSha256"]?.stringValue, "live view, prefix \(n)")
		}
	}
}

@Suite struct TranscriptCompactionGoldenTests {
	@Test(arguments: [Fixtures.teachChatId, Fixtures.practiceChatId])
	func estimatesAndCutsMatchTS(chatId: String) throws {
		let golden = try Golden.load("transcript.compaction.\(chatId)")
		let record = try Fixtures.chat(chatId)
		let messages = record.messages

		let perMessage: JSONValue = .array(messages.map { ["id": .string($0.id), "tokens": .number(estimateMessageTokens($0))] })
		expectJSONEqual(perMessage, golden["messageTokens"]!)
		#expect(estimateTokens(messages) == golden["estimateTokens"]?.intValue)
		#expect(compactionCutIndex(messages) == golden["cut"]?.intValue)
		for row in golden["cuts"]?.arrayValue ?? [] {
			let budget = try #require(row["budget"]?.intValue)
			#expect(compactionCutIndex(messages, keepRecentTokens: budget) == row["cut"]?.intValue, "budget \(budget)")
		}
		for row in golden["contexts"]?.arrayValue ?? [] {
			let n = try #require(row["n"]?.intValue)
			let prefix = Array(messages.prefix(n))
			let actual: JSONValue = [
				"n": .number(n),
				"estimate": estimateContextTokens(prefix).json,
				"cut": .number(compactionCutIndex(prefix)),
				"cut5k": .number(compactionCutIndex(prefix, keepRecentTokens: 5_000)),
				"planTreeText": planTreeToText(record.tree, prefix).map(JSONValue.string) ?? .null,
			]
			expectJSONEqual(actual, row)
		}
	}

	@Test(arguments: [Fixtures.teachChatId, Fixtures.practiceChatId])
	func summarizerInputsMatchTS(chatId: String) throws {
		let golden = try Golden.load("transcript.compaction.\(chatId)")
		let record = try Fixtures.chat(chatId)
		let messages = record.messages
		let cut5k = compactionCutIndex(messages, keepRecentTokens: 5_000)
		let span = serializeForSummary(Array(messages.prefix(cut5k)))

		#expect(serializeForSummary(messages) == golden["serializeFull"]?.stringValue)
		#expect(span == golden["serializeSpan5k"]?.stringValue)

		let active: JSONValue = activeCompactionOf(messages).map { c in
			["id": .string(c.id), "content": .string(c.content), "details": c.details, "keptIndex": .number(keptIndexFor(messages, c))]
		} ?? .null
		expectJSONEqual(active, golden["active"]!)

		let kind = CompactionPromptKind(rawValue: record.resolvedKind.rawValue)!
		#expect(buildCompactionPrompt(spanText: span, planTreeText: planTreeToText(record.tree, messages), kind: kind) == golden["prompt"]?.stringValue)
		#expect(buildCompactionPrompt(spanText: "TRANSCRIPT", planTreeText: nil, kind: .practice) == golden["promptNoTree"]?.stringValue)

		let marker = newCompactionMarker(summary: "  The learner knows X.\n\n", details: CompactionDetails(
			firstKeptMessageId: cut5k < messages.count ? messages[cut5k].id : "none",
			tokensBefore: estimateContextTokens(messages).tokens, model: "claude-opus-5-5", at: "2026-10-05T12:00:00.000Z"))
		#expect(marker.marker?.content == golden["markerContent"]?.stringValue)
	}
}
