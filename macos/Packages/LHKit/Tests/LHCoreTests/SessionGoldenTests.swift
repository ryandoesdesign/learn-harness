import Foundation
import Testing
@testable import LHCore

/// Session-area parity with the TS dumps (scripts/core-golden/session.ts).
@Suite struct SessionGoldenTests {
	static let chats = [Fixtures.teachChatId, Fixtures.practiceChatId]

	/// A plan-block marker's comparable face (`at` normalized).
	private func blockFace(_ m: Message) throws -> JSONValue {
		let marker = try #require(m.marker)
		var block = try #require(marker.details["block"])
		block["at"] = "<at>"
		return ["planCallId": marker.details["planCallId"] ?? .null, "block": block]
	}

	@Test(arguments: chats)
	func phasesMatchTS(chatId: String) throws {
		let golden = try Golden.load("session.\(chatId)")
		let messages = try Fixtures.chat(chatId).messages
		let prefix = try #require(golden["prefixPhases"]?.arrayValue)
		#expect(prefix.count == messages.count + 1)
		for (n, expected) in prefix.enumerated() {
			#expect(phaseAt3Lh(Array(messages.prefix(n))).rawValue == expected.stringValue, "prefix \(n)")
		}
		let upTo = try #require(golden["upTo"]?.arrayValue)
		let timeline = phaseTimeline(messages)
		for (i, expected) in upTo.enumerated() {
			#expect(phaseAt3Lh(messages, upToIndex: i).rawValue == expected.stringValue, "upTo \(i)")
			#expect(timeline[i].rawValue == expected.stringValue, "timeline \(i)")
		}
	}

	@Test(arguments: chats)
	func teachStepIndexMatchesTheView(chatId: String) throws {
		let golden = try Golden.load("session.\(chatId)")
		let messages = try Fixtures.chat(chatId).messages
		for row in golden["teachSteps"]?.arrayValue ?? [] {
			let groupId = try #require(row["groupId"]?.stringValue)
			let callId = try #require(row["flipCallId"]?.stringValue)
			let start = try #require(messages.firstIndex { $0.id == groupId })
			let end = try #require(messages[start...].firstIndex { $0.assistant?.toolUses.contains { $0.id == callId } ?? false })
			let group = Array(messages[start...end])
			let index = teachStepIndex(group)
			let tsIndex = try #require(row["index"]?.intValue)
			#expect((index == -1) == (tsIndex == -1), "group \(groupId)")
			// The call's step number (the view's step-starts up to its part).
			let steps = group.filter { !($0.assistant?.content.isEmpty ?? true) }.count
			#expect(steps == row["stepOrdinal"]?.intValue, "group \(groupId)")
			if index != -1 { #expect(group[index].assistant?.toolUses.contains { $0.id == callId } == true) }
		}
	}

	@Test(arguments: chats)
	func planBlocksMatchTS(chatId: String) throws {
		let golden = try Golden.load("session.\(chatId)")
		let chat = try Fixtures.chat(chatId)
		let messages = chat.messages
		expectJSONEqual(.array(emittedPlanBlockCalls(messages).sorted().map(JSONValue.string)), golden["emittedPlanBlockCalls"]!)

		let bare = messages.filter { $0.marker?.kind != .planBlock }
		let pb = try #require(golden["planBlocks"])
		expectJSONEqual(.array(try planBlocksFor(record: [], newMessages: bare, tree: chat.tree, transcript: bare).map(blockFace)), pb["wholeTurn"]!)
		expectJSONEqual(.array(try planBlocksFor(record: messages, newMessages: messages, tree: chat.tree, transcript: messages).map(blockFace)), pb["replay"]!)

		let starts = bare.indices.filter { $0 == 0 || bare[$0].role == .user }
		var seen: [Message] = []
		var perTurn: [JSONValue] = []
		for (k, s) in starts.enumerated() {
			let turn = Array(bare[s..<(k + 1 < starts.count ? starts[k + 1] : bare.count)])
			let blocks = planBlocksFor(record: seen, newMessages: turn, tree: chat.tree, transcript: seen + turn)
			perTurn.append(["start": .number(s), "blocks": .array(try blocks.map(blockFace))])
			seen += turn + blocks
		}
		expectJSONEqual(.array(perTurn), pb["perTurn"]!)
	}

	@Test(arguments: chats)
	func markdownIsByteIdentical(chatId: String) throws {
		let golden = try Golden.load("session.\(chatId)")
		let chat = try Fixtures.chat(chatId)
		let messages = chat.messages
		let rows = try #require(golden["messageMarkdown"]?.arrayValue)
		#expect(rows.count == messages.count)
		for (m, row) in zip(messages, rows) {
			#expect(m.id == row["id"]?.stringValue)
			#expect(messageMarkdown(m, m.id) == row["anchored"]?.stringValue, "anchored \(m.id)")
			#expect(messageMarkdown(m, m.id, anchors: false) == row["bare"]?.stringValue, "bare \(m.id)")
		}
		let docs = try #require(golden["sessionMarkdown"])
		#expect(sessionMarkdown(messages) == docs["default"]?.stringValue)
		#expect(sessionMarkdown(messages, anchors: false) == docs["noAnchors"]?.stringValue)
		#expect(sessionMarkdown(messages, title: chat.title) == docs["titled"]?.stringValue)
		#expect(sessionMarkdown(messages, title: chat.title, anchors: false) == docs["titledNoAnchors"]?.stringValue)
		#expect(sessionMarkdown(messages, title: "") == docs["emptyTitle"]?.stringValue)
	}
}
