import Foundation
import LHAnthropic
import LHCore

/// The record → `messages[]` seam (docs/native-macos-m3.md, "WireProjection"):
/// a port of native-messages.ts `toLlmMessages` plus the pi-ai transform
/// rules that ran after it. A pure function of the record: the same record
/// always projects to the same bytes, and appending to the record only
/// appends to the projection (the preserved-thinking prefix law).
public enum WireProjection {
	public struct Options: Sendable, Hashable {
		/// Strip every thinking block before the probe-handoff marker (the
		/// teach phase runs under a different system prompt and tool set).
		public var stripProberThinking: Bool
		public init(stripProberThinking: Bool = false) { self.stripProberThinking = stripProberThinking }
	}

	public static let errorImagePlaceholder = "(image attached after the tool results)"

	/// Anthropic's tool-use id shape.
	static func isValidToolId(_ id: String) -> Bool {
		!id.isEmpty && id.utf8.count <= 64 && id.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D }
	}

	public static func project(_ messages: [Message], options: Options = Options()) -> [WireMessage] {
		// The compaction cut: the active marker names the first kept message;
		// everything before it becomes the marker's text, rendered once up top.
		var start = 0
		var keptEnd = -1 // retained turns (before the marker) lose their thinking
		var activeId: String?
		var out: [Entry] = []
		if let active = activeCompactionOf(messages) {
			let kept = keptIndexFor(messages, active)
			if kept > 0 {
				start = kept
				activeId = active.id
				keptEnd = messages.firstIndex { $0.id == active.id } ?? -1
				out.append(.user([.object(JSONObject(["type": "text", "text": .string(active.content)]))]))
			}
		}
		let handoffIndex = options.stripProberThinking ? (messages.firstIndex { $0.marker?.kind == .probeHandoff } ?? -1) : -1

		var ids = ToolIdMap()
		var emittedCalls = Set<String>() // original ids of tool_use blocks on the wire
		var answered = Set<String>()
		for i in start..<messages.count {
			let m = messages[i]
			switch m.body {
			case .marker(let marker):
				if marker.kind == .planBlock || marker.kind == .problemDismissed { continue }
				if marker.kind == .compaction, m.id == activeId { continue }
				if marker.content.isEmpty { continue }
				out.append(.user([textBlock(marker.content)]))
			case .user(let u):
				let content = u.content.filter { !isEmptyText($0) }.map(\.raw)
				if !content.isEmpty { out.append(.user(content)) }
			case .assistant(let a):
				if ["aborted", "error", "refusal"].contains(a.stopReason) { continue }
				let stripThinking = (i < keptEnd) || (i < handoffIndex)
				var blocks = assistantBlocks(a.content, stripThinking: stripThinking)
				if blocks.isEmpty { continue }
				var calls: [(id: String, name: String)] = []
				blocks = blocks.map { b in
					guard b["type"]?.stringValue == "tool_use", let id = b["id"]?.stringValue else { return b }
					calls.append((id, b["name"]?.stringValue ?? ""))
					emittedCalls.insert(id)
					let wireId = ids.call(id)
					guard wireId != id else { return b }
					var c = b
					c["id"] = .string(wireId)
					return c
				}
				out.append(.assistant(blocks))
				// Dangling-call synthesis: calls with no result anywhere after.
				let later = Set(messages[(i + 1)...].compactMap { $0.toolResult?.toolUseId })
				for call in calls where !later.contains(call.id) {
					out.append(.result(toolResult(id: ids.result(call.id), content: [textBlock(INTERRUPTED_TEXT)], isError: false), extra: []))
					answered.insert(call.id)
				}
			case .toolResult(let r):
				// Orphans (their call was dropped or never projected) and repeats never reach the wire.
				guard emittedCalls.contains(r.toolUseId), !answered.contains(r.toolUseId) || ids.hasPendingDuplicate(r.toolUseId) else { continue }
				answered.insert(r.toolUseId)
				var content = r.content.map(\.raw)
				var extra: [JSONValue] = []
				if r.isError, content.contains(where: { $0["type"]?.stringValue == "image" }) {
					let images = content.filter { $0["type"]?.stringValue == "image" }
					content = replaceImages(content)
					extra = [textBlock("Images from the error result of tool call \(r.toolUseId) (\(r.toolName)):")] + images
				}
				out.append(.result(toolResult(id: ids.result(r.toolUseId), content: content, isError: r.isError), extra: extra))
			}
		}
		return merge(out)
	}

	// MARK: Assistant content

	/// Fallback echo rule, unsigned-thinking drop, optional thinking strip.
	static func assistantBlocks(_ content: [Block], stripThinking: Bool) -> [JSONValue] {
		let lastFallback = content.lastIndex { $0.type == "fallback" }
		let pairedServerIds = Set(content.compactMap { b -> String? in
			guard b.type.hasSuffix("_tool_result") else { return nil }
			return b.raw["tool_use_id"]?.stringValue
		})
		var out: [JSONValue] = []
		for (i, b) in content.enumerated() {
			switch b.type {
			case "fallback":
				continue
			case "thinking":
				if stripThinking { continue }
				if let lf = lastFallback, i < lf { continue }
				// Unsigned thinking (imported from another provider) can't be replayed.
				if b.raw["signature"]?.stringValue?.isEmpty ?? true { continue }
				out.append(b.raw)
			case "redacted_thinking":
				if stripThinking { continue }
				if let lf = lastFallback, i < lf { continue }
				out.append(b.raw)
			case "tool_use":
				if let lf = lastFallback, i < lf { continue }
				out.append(b.raw)
			case "server_tool_use":
				if let lf = lastFallback, i < lf, !pairedServerIds.contains(b.raw["id"]?.stringValue ?? "") { continue }
				out.append(b.raw)
			case "text":
				if isEmptyText(b) { continue }
				out.append(b.raw)
			default:
				out.append(b.raw)
			}
		}
		return out
	}

	static func isEmptyText(_ b: Block) -> Bool { b.type == "text" && (b.text ?? "").isEmpty }

	static func textBlock(_ text: String) -> JSONValue { ["type": "text", "text": .string(text)] }

	static func toolResult(id: String, content: [JSONValue], isError: Bool) -> JSONValue {
		var o = JSONObject(["type": "tool_result", "tool_use_id": .string(id), "content": .array(content)])
		if isError { o["is_error"] = true }
		return .object(o)
	}

	/// Images → one placeholder per consecutive run (error results can't carry images).
	static func replaceImages(_ content: [JSONValue]) -> [JSONValue] {
		var out: [JSONValue] = []
		var previousWasPlaceholder = false
		for b in content {
			if b["type"]?.stringValue == "image" {
				if !previousWasPlaceholder { out.append(textBlock(errorImagePlaceholder)) }
				previousWasPlaceholder = true
				continue
			}
			out.append(b)
			previousWasPlaceholder = b["text"]?.stringValue == errorImagePlaceholder
		}
		return out
	}

	// MARK: Merging

	enum Entry {
		case user([JSONValue])
		case assistant([JSONValue])
		/// A tool_result block plus blocks that must follow all results (error-result images).
		case result(JSONValue, extra: [JSONValue])
	}

	/// Consecutive user-role entries merge into one message, tool_result
	/// blocks first (record order kept within each group), then text and
	/// images, then error-result image attachments.
	static func merge(_ entries: [Entry]) -> [WireMessage] {
		var out: [WireMessage] = []
		var results: [JSONValue] = []
		var others: [JSONValue] = []
		var trailing: [JSONValue] = []
		func flush() {
			let content = results + others + trailing
			if !content.isEmpty { out.append(WireMessage(role: .user, content: content)) }
			results = []
			others = []
			trailing = []
		}
		for e in entries {
			switch e {
			case .assistant(let blocks):
				flush()
				out.append(WireMessage(role: .assistant, content: blocks))
			case .user(let blocks):
				others += blocks
			case .result(let block, let extra):
				results.append(block)
				trailing += extra
			}
		}
		flush()
		return out
	}

	// MARK: Tool ids

	/// Deterministic tool-id normalization for imported history: ids that
	/// break Anthropic's `^[a-zA-Z0-9_-]{1,64}$` or repeat an earlier call's
	/// id (DeepSeek's per-response `call_0`) are reminted `lh_<n>_<sanitized>`
	/// in order of appearance; a result maps to the newest call carrying its id.
	struct ToolIdMap {
		private var current: [String: String] = [:]
		private var used = Set<String>()
		private var minted = 0
		private var resultsPending: [String: Int] = [:]

		mutating func call(_ id: String) -> String {
			resultsPending[id, default: 0] += 1
			if WireProjection.isValidToolId(id), !used.contains(id) {
				used.insert(id)
				current[id] = id
				return id
			}
			minted += 1
			let clean = String(String(id.unicodeScalars.map { s -> Character in
				(("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s) || s == "_" || s == "-") ? Character(s) : "_"
			}).prefix(48))
			var fresh = "lh_\(minted)_\(clean)"
			while used.contains(fresh) {
				minted += 1
				fresh = "lh_\(minted)_\(clean)"
			}
			used.insert(fresh)
			current[id] = fresh
			return fresh
		}

		mutating func result(_ id: String) -> String {
			if let n = resultsPending[id], n > 0 { resultsPending[id] = n - 1 }
			return current[id] ?? id
		}

		/// A repeated original id whose newer call still awaits its result.
		func hasPendingDuplicate(_ id: String) -> Bool { (resultsPending[id] ?? 0) > 0 }
	}
}
