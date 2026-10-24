import Foundation
import Testing
import LHAnthropic
@testable import LHAgent
@testable import LHCore

enum Repo {
	static let root: URL = {
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<6 { url.deleteLastPathComponent() }
		return url
	}()

	static func goldenChat(_ id: String) throws -> ChatRecord {
		let url = root.appending(path: "tests/fixtures/golden-data/chats/\(id).json")
		return try #require(ChatRecord(legacyJSON: JSONValue.parse(Data(contentsOf: url))))
	}

	static let chatIds = ["chat_mv27rrra_feff23b6", "chat_mv293wv5_10656952"]
}

// MARK: Builders

func user(_ id: String, _ text: String) -> Message { newUserMessage(text, id: id, now: 1) }

func assistant(_ id: String, _ blocks: [Block], stop: String = "end_turn", model: String = "claude-opus-5-5") -> Message {
	Message(id: id, timestamp: 1, body: .assistant(AssistantBody(content: blocks, model: model, stopReason: stop)))
}

func result(_ id: String, call: String, name: String = "t", _ text: String = "ok", isError: Bool = false, content: [Block]? = nil) -> Message {
	Message(id: id, timestamp: 1, body: .toolResult(ToolResultBody(toolUseId: call, toolName: name, content: content ?? [.text(text)], isError: isError, details: ["d": 1])))
}

func marker(_ id: String, _ kind: MarkerKind, _ content: String, details: JSONValue = [:]) -> Message {
	Message(id: id, timestamp: 1, body: .marker(MarkerBody(kind: kind, content: content, details: details)))
}

func think(_ t: String, sig: String? = "sig") -> Block { .thinking(t, signature: sig) }
func call(_ id: String, _ name: String = "t", _ input: JSONValue = [:]) -> Block { .toolUse(id: id, name: name, input: input) }

func wire(_ m: [Message], _ o: WireProjection.Options = .init()) -> String {
	JSONValue.array(WireProjection.project(m, options: o).map(\.json)).serialized()
}

// MARK: Tests

@Suite struct WireProjectionTests {
	@Test func anthropicBlocksPassThroughByteForByte() {
		let tu = call("toolu_A", "quiz", ["q": "why?", "n": 1.50])
		let record = [user("u1", "hi"), assistant("a1", [think("hmm", sig: "S1"), .text("Q:"), tu], stop: "tool_use"), result("r1", call: "toolu_A", name: "quiz", "ans")]
		#expect(wire(record) == #"[{"role":"user","content":[{"type":"text","text":"hi"}]},{"role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"S1"},{"type":"text","text":"Q:"},{"type":"tool_use","id":"toolu_A","name":"quiz","input":{"q":"why?","n":1.5}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_A","content":[{"type":"text","text":"ans"}]}]}]"#)
	}

	@Test func dropsAbortedErrorAndRefusedTurnsAndTheirOrphanResults() {
		let record = [
			user("u1", "a"),
			assistant("a1", [.text("partial"), call("toolu_X")], stop: "aborted"),
			result("r1", call: "toolu_X", "Operation aborted", isError: true),
			assistant("a2", [.text("boom")], stop: "error"),
			assistant("a3", [.text("no")], stop: "refusal"),
			user("u2", "b"),
		]
		#expect(wire(record) == #"[{"role":"user","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}]"#)
	}

	@Test func danglingCallsGetTheInterruptedResultAndStepsMergeBehindResults() {
		let record = [
			user("u1", "a"),
			assistant("a1", [call("toolu_1", "quiz"), call("toolu_2", "research")], stop: "tool_use"),
			result("r2", call: "toolu_2", name: "research", "Dispatched"),
			marker("s1", .subagentSteer, "brief arrived"),
		]
		let w = WireProjection.project(record)
		#expect(w.count == 3)
		let last = JSONValue.array(w[2].content).serialized()
		#expect(last == #"[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"\#(INTERRUPTED_TEXT)"}]},{"type":"tool_result","tool_use_id":"toolu_2","content":[{"type":"text","text":"Dispatched"}]},{"type":"text","text":"brief arrived"}]"#)
	}

	@Test func uiOnlyMarkersNeverReachTheWire() {
		let record = [user("u1", "a"), marker("pb", .planBlock, "", details: ["planCallId": "x"]), marker("pd", .problemDismissed, "", details: ["problemCallId": "p"]), marker("h", .probeHandoff, HANDOFF_TEXT)]
		#expect(wire(record) == #"[{"role":"user","content":[{"type":"text","text":"a"},{"type":"text","text":"\#(HANDOFF_TEXT)"}]}]"#)
	}

	@Test func unsignedForeignThinkingIsDroppedAndEmptyTextSkipped() {
		let record = [user("u1", "a"), assistant("a1", [think("foreign", sig: nil), .text(""), .text("hello")], model: "openrouter:deepseek/x"), user("u2", "b")]
		#expect(wire(record) == #"[{"role":"user","content":[{"type":"text","text":"a"}]},{"role":"assistant","content":[{"type":"text","text":"hello"}]},{"role":"user","content":[{"type":"text","text":"b"}]}]"#)
	}

	@Test func fallbackEchoRuleDropsPreBoundaryInternals() {
		let fallback = Block(raw: ["type": "fallback", "from": ["model": "claude-opus-5-5"], "to": ["model": "claude-opus-5"]])
		let serverUnpaired = Block(raw: ["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": ["query": "q"]])
		let record = [
			user("u1", "a"),
			assistant("a1", [think("t1", sig: "s"), .text("Before "), call("toolu_pre"), serverUnpaired, fallback, think("t2", sig: "s2"), .text("after")], model: "claude-opus-5"),
		]
		#expect(wire(record) == #"[{"role":"user","content":[{"type":"text","text":"a"}]},{"role":"assistant","content":[{"type":"text","text":"Before "},{"type":"thinking","thinking":"t2","signature":"s2"},{"type":"text","text":"after"}]}]"#)
	}

	@Test func errorResultImagesMoveBehindTheResults() {
		let img = Block.image(mediaType: "image/png", base64: "AAAA")
		let record = [
			user("u1", "a"),
			assistant("a1", [call("toolu_1", "read"), call("toolu_2", "read")], stop: "tool_use"),
			result("r1", call: "toolu_1", name: "read", isError: true, content: [.text("failed"), img, img]),
			result("r2", call: "toolu_2", name: "read", "fine"),
		]
		let last = JSONValue.array(WireProjection.project(record)[2].content).serialized()
		#expect(last == #"[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"failed"},{"type":"text","text":"(image attached after the tool results)"}],"is_error":true},{"type":"tool_result","tool_use_id":"toolu_2","content":[{"type":"text","text":"fine"}]},{"type":"text","text":"Images from the error result of tool call toolu_1 (read):"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]"#)
	}

	@Test func duplicateAndInvalidImportedIdsAreRemintedDeterministically() {
		let record = [
			user("u1", "a"),
			assistant("a1", [call("call_0", "find")], stop: "tool_use", model: "openrouter:x"),
			result("r1", call: "call_0", name: "find", "one"),
			assistant("a2", [call("call_0", "find"), call("bad|id", "grep")], stop: "tool_use", model: "openrouter:x"),
			result("r2", call: "call_0", name: "find", "two"),
			result("r3", call: "bad|id", name: "grep", "three"),
		]
		let w = WireProjection.project(record)
		#expect(w[1].content[0]["id"] == "call_0")
		#expect(w[2].content[0]["tool_use_id"] == "call_0")
		#expect(w[3].content[0]["id"] == "lh_1_call_0")
		#expect(w[3].content[1]["id"] == "lh_2_bad_id")
		#expect(w[4].content.map { $0["tool_use_id"] } == ["lh_1_call_0", "lh_2_bad_id"])
		#expect(w[4].content.map { $0["content"]?[0]?["text"] } == ["two", "three"])
		#expect(wire(record) == wire(record))
	}

	@Test func proberEraThinkingIsStrippedAfterTheHandoff() {
		let record = [
			user("u1", "a"),
			assistant("a1", [think("probe", sig: "p"), .text("probing")]),
			marker("h", .probeHandoff, HANDOFF_TEXT),
			assistant("a2", [think("teach", sig: "t"), .text("teaching")]),
		]
		let w = WireProjection.project(record, options: .init(stripProberThinking: true))
		#expect(w[1].content.map { $0["type"] } == ["text"])
		#expect(w[3].content.map { $0["type"] } == ["thinking", "text"])
	}

	@Test func compactionRendersTheSummaryOnceAndStripsRetainedThinking() {
		let record = [
			user("u1", "old"),
			assistant("a1", [.text("old answer")]),
			user("u2", "kept question"),
			assistant("a2", [think("kept", sig: "k"), .text("kept answer")]),
			marker("c1", .compaction, "SUMMARY", details: ["firstKeptMessageId": "u2"]),
			user("u3", "new"),
			assistant("a3", [think("fresh", sig: "f"), .text("fresh answer")]),
		]
		#expect(wire(record) == #"[{"role":"user","content":[{"type":"text","text":"SUMMARY"},{"type":"text","text":"kept question"}]},{"role":"assistant","content":[{"type":"text","text":"kept answer"}]},{"role":"user","content":[{"type":"text","text":"new"}]},{"role":"assistant","content":[{"type":"thinking","thinking":"fresh","signature":"f"},{"type":"text","text":"fresh answer"}]}]"#)
	}

	@Test func goldenChatsProjectToLegalAlternatingHistories() throws {
		for id in Repo.chatIds {
			let record = try Repo.goldenChat(id)
			let w = WireProjection.project(record.messages, options: .init(stripProberThinking: hasProbeDone(record.messages)))
			#expect(w.first?.role == .user)
			for (a, b) in zip(w, w.dropFirst()) { #expect(a.role != b.role, "\(id): roles alternate") }
			var open = Set<String>()
			for m in w {
				for b in m.content {
					#expect(b["type"] != "thinking", "\(id): foreign thinking never replays")
					if b["type"] == "tool_use", let i = b["id"]?.stringValue {
						#expect(WireProjection.isValidToolId(i))
						open.insert(i)
					}
					if b["type"] == "tool_result", let i = b["tool_use_id"]?.stringValue { #expect(open.remove(i) != nil, "\(id): result pairs a call") }
				}
			}
			#expect(open.isEmpty, "\(id): every call answered")
		}
	}
}

/// THE prefix-stability property (docs/native-macos-m3.md): at every request
/// boundary (a record prefix ending where the next assistant message would
/// be generated), projecting the prefix yields an exact byte prefix of the
/// projection of the full record — appending never edits what was sent.
@Suite struct PrefixStabilityTests {
	/// Request boundaries: indices i where messages[i] is an assistant message
	/// (the request that produced it saw exactly messages[0..<i]).
	func boundaries(_ m: [Message]) -> [Int] {
		m.indices.filter { m[$0].role == .assistant && !["aborted", "error", "refusal"].contains(m[$0].assistant!.stopReason) }
	}

	/// `from`: the first boundary that runs under the same regime as the end
	/// (a handoff or a compaction deliberately restarts the prefix).
	func check(_ messages: [Message], _ options: WireProjection.Options = .init(), from: Int = 0, sourceLocation: SourceLocation = #_sourceLocation) {
		let full = WireProjection.project(messages, options: options).map { $0.json.serialized() }
		for b in boundaries(messages) where b >= from {
			let prefix = WireProjection.project(Array(messages[..<b]), options: options).map { $0.json.serialized() }
			// The request ended with a user message; it must be the full wire's message at that position, unchanged.
			let ok = prefix.count <= full.count && Array(full.prefix(prefix.count)) == prefix
			#expect(ok, "boundary \(b): the request prefix was edited later", sourceLocation: sourceLocation)
		}
	}

	@Test func goldenChats() throws {
		for id in Repo.chatIds {
			let m = try Repo.goldenChat(id).messages
			// A compaction restarts the prefix: before it, the record as it
			// stood then; after it, the summary regime.
			if let cut = activeCompactionOf(m).flatMap({ a in m.firstIndex { $0.id == a.id } }) {
				check(Array(m[..<cut]))
				check(m, from: cut + 1)
			} else {
				check(m)
			}
			#expect(boundaries(m).count > 3, "\(id): enough boundaries to mean something")
		}
	}

	@Test func steersAbortsRefusalsAndToolRounds() {
		check([
			user("u1", "a"),
			assistant("a1", [think("x"), call("toolu_1", "research")], stop: "tool_use"),
			result("r1", call: "toolu_1", "Dispatched"),
			marker("st1", .subagentSteer, "brief"),
			assistant("a2", [think("y"), .text("woven")]),
			user("u2", "next"),
			assistant("a3", [.text("part")], stop: "aborted"),
			user("u3", "again"),
			assistant("a4", [.text("no")], stop: "refusal"),
			user("u4", "ok then"),
			assistant("a5", [think("z"), .text("fine")]),
		])
	}

	@Test func withinTheTeachPhaseAfterTheHandoff() {
		check([
			user("u1", "a"),
			assistant("a1", [think("p"), .text("probe")]),
			marker("h", .probeHandoff, HANDOFF_TEXT),
			assistant("a2", [think("t"), .text("plan")]),
			user("u2", "go"),
			assistant("a3", [think("t2"), .text("teach")]),
		], WireProjection.Options(stripProberThinking: true), from: 3)
	}

	@Test func afterACompaction() {
		check([
			user("u1", "old"),
			assistant("a1", [think("o"), .text("old")]),
			user("u2", "kept"),
			assistant("a2", [think("k"), .text("kept")]),
			marker("c1", .compaction, "SUMMARY", details: ["firstKeptMessageId": "u2"]),
			user("u3", "new"),
			assistant("a3", [think("f"), .text("fresh")]),
			user("u4", "more"),
			assistant("a4", [think("g"), .text("more")]),
		], from: 6)
	}
}
