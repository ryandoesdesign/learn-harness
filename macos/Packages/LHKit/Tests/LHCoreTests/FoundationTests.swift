import Foundation
import Testing
@testable import LHCore

@Suite struct JSONValueTests {
	@Test func roundTripsGoldenChatsByteForByte() throws {
		for id in [Fixtures.teachChatId, Fixtures.practiceChatId] {
			let data = try Data(contentsOf: Fixtures.goldenData.appending(path: "chats/\(id).json"))
			let text = String(decoding: data, as: UTF8.self)
			let parsed = try JSONValue.parse(text)
			// The golden chat files are JSON.stringify(record, null, "\t").
			#expect(parsed.serialized(indentUnit: "\t") == text.trimmingCharacters(in: .newlines))
		}
	}

	@Test func roundTripsLedgerLinesByteForByte() throws {
		let text = try String(contentsOf: Fixtures.goldenData.appending(path: "graph/nodes.jsonl"), encoding: .utf8)
		for line in text.split(separator: "\n") {
			#expect(try JSONValue.parse(String(line)).serialized() == String(line))
		}
	}

	@Test func jsNumberFormatting() {
		#expect(JSONNumber(1.0).lexeme == "1")
		#expect(JSONNumber(0.1).lexeme == "0.1")
		#expect(JSONNumber(1e-7).lexeme == "1e-7")
		#expect(JSONNumber(1.5e21).lexeme == "1.5e+21")
		#expect(JSONNumber(-0.0).lexeme == "0")
	}

	@Test func stringEscapesMatchJS() {
		#expect(JSONValue.quote("a\"b\\c\n\u{01}é/") == "\"a\\\"b\\\\c\\n\\u0001é/\"")
	}

	@Test func objectKeepsInsertionOrderAndLastWriteWins() throws {
		let v = try JSONValue.parse(#"{"b":1,"a":2,"b":3}"#)
		#expect(v.serialized() == #"{"b":3,"a":2}"#)
	}

	@Test func jsStringSemantics() {
		#expect("a😀b".jsLength == 4)
		#expect("a😀b".jsSlice(0, 3) == "a😀")
		#expect("hello".jsSlice(-3) == "llo")
	}
}

@Suite struct LegacyConversionTests {
	@Test func convertsEveryGoldenMessage() throws {
		for id in [Fixtures.teachChatId, Fixtures.practiceChatId] {
			let raw = try Fixtures.json("chats/\(id).json")
			let record = try Fixtures.chat(id)
			#expect(record.messages.count == raw["messages"]?.arrayValue?.count)
		}
	}

	@Test func mapsBlockShapes() throws {
		let record = try Fixtures.teachChat
		let assistant = try #require(record.messages.compactMap(\.assistant).first)
		#expect(assistant.model == "openrouter:deepseek/deepseek-v4.1-flash")
		// Foreign (OpenRouter) thinking keeps its text but loses the signature.
		let thinking = try #require(assistant.content.compactMap(\.thinking).first)
		#expect(thinking.signature == nil)
		#expect(!thinking.text.isEmpty)
		let toolUses = record.messages.compactMap(\.assistant).flatMap(\.toolUses)
		#expect(toolUses.contains { $0.name == "list_sessions" })
		let result = try #require(record.messages.compactMap(\.toolResult).first)
		#expect(toolUses.contains { $0.id == result.toolUseId })
		#expect(record.messages.compactMap(\.marker).contains { $0.kind == .planBlock })
	}

	@Test func anthropicThinkingKeepsSignature() throws {
		let pi: JSONValue = [
			"id": "m1", "role": "assistant", "provider": "anthropic", "model": "claude-opus-5-5", "stopReason": "toolUse",
			"timestamp": 1,
			"content": [
				["type": "thinking", "thinking": "hmm", "thinkingSignature": "sig"],
				["type": "thinking", "thinking": "", "thinkingSignature": "opaque", "redacted": true],
				["type": "toolCall", "id": "t1", "name": "quiz", "arguments": ["q": 1]],
			],
		]
		let m = try #require(LegacyRecordConversion.message(fromPi: pi))
		let a = try #require(m.assistant)
		#expect(a.model == "claude-opus-5-5")
		#expect(a.stopReason == "tool_use")
		#expect(a.content[0].raw.serialized() == #"{"type":"thinking","thinking":"hmm","signature":"sig"}"#)
		#expect(a.content[1].raw.serialized() == #"{"type":"redacted_thinking","data":"opaque"}"#)
		#expect(a.content[2].raw.serialized() == #"{"type":"tool_use","id":"t1","name":"quiz","input":{"q":1}}"#)
	}

	@Test func messageEnvelopeRoundTrips() throws {
		for m in try Fixtures.teachChat.messages {
			#expect(Message(json: m.json) == m)
		}
	}
}

@Suite struct FoundationGoldenTests {
	@Test func planStatusesMatchTS() throws {
		let record = try Fixtures.teachChat
		let s = derivePlanStatuses(try #require(record.tree), record.messages)
		let actual: JSONValue = ["current": s.current.map(JSONValue.string) ?? .null, "visited": .array(s.visited.sorted().map(JSONValue.string))]
		expectJSONEqual(actual, try Golden.load("foundation.planStatuses"))
	}

	@Test func titlesMatchTS() throws {
		for case let row in try Golden.load("foundation.titles").arrayValue ?? [] {
			#expect(titleFromPrompt(row["input"]!.stringValue!) == row["output"]!.stringValue!)
		}
	}
}

@Suite struct NullDetailsTests {
	@Test func nullToolResultDetailsReadAsAbsent() throws {
		let pi: JSONValue = ["id": "r", "role": "toolResult", "toolCallId": "c", "toolName": "x", "content": [], "isError": false, "details": nil, "timestamp": 1]
		let m = try #require(LegacyRecordConversion.message(fromPi: pi))
		#expect(m.toolResult?.details == nil)
	}
}
