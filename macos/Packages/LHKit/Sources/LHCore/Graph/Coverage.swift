import CryptoKit
import Foundation

// Port of src/core/coverage.ts — extraction coverage, the pure core. THE
// TEACHER'S PROSE IS THE UNIT: the extractor sees only the teacher's text
// blocks; everything else is invisible to coverage (it neither opens nor
// joins a run). A per-chat append-only ledger records extracted messages by
// CONTENT FINGERPRINT; "uncovered" is derived at read time. Runs are
// token-budgeted greedy batches of the oldest uncovered teacher prose.
//
// Fingerprints are persisted (coverage.jsonl), so they must equal the TS
// digests byte-for-byte: the hash input is the pi-era role name ("custom"
// for markers) and the view lines, serialized exactly like JSON.stringify.

/// The non-blank text blocks of a message's content.
private func textOf(_ content: [Block]) -> [String] {
	content.compactMap(\.text).filter { !$0.jsTrimmed.isEmpty }
}

private func assistantContent(_ message: Message) -> [Block]? {
	if case .assistant(let a) = message.body { return a.content }
	return nil
}

/// The extraction-relevant lines of ONE message — the shared seam between the
/// extractor's prompt and the fingerprint. An assistant message yields one
/// `TEACHER [mid] text` line per non-blank text block; everything else
/// yields nothing.
public func messageViewLines(_ message: Message, mid: String) -> [String] {
	guard let content = assistantContent(message) else { return [] }
	return textOf(content).map { "TEACHER [\(mid)] \($0.jsTrimmed)" }
}

/// The teacher's prose blocks of a transcript, in order — the extractor's
/// prompt material (same selection as messageViewLines, unprefixed).
public func teacherProseBlocks(_ messages: [Message]) -> [String] {
	messages.flatMap { m in assistantContent(m).map { textOf($0).map(\.jsTrimmed) } ?? [] }
}

/// Tokens of a message's view — chars/4 (UTF-16), ceil.
public func viewTokens(_ lines: [String]) -> Int {
	(lines.joined(separator: "\n").jsLength + 3) / 4
}

/// The pi record's role name (the fingerprint's hash input).
private func piRole(_ role: Message.Role) -> String {
	role == .marker ? "custom" : role.rawValue
}

/// A message's coverage fingerprint: sha256 hex of
/// `JSON.stringify([role, viewLines])`. Changes exactly when the teacher
/// prose (or the id tag) changes.
public func messageFingerprint(_ message: Message) -> String {
	let input: JSONValue = .array([.string(piRole(message.role)), .array(messageViewLines(message, mid: message.id).map(JSONValue.string))])
	return GraphJS.hex(SHA256.hash(data: Data(input.serialized().utf8)))
}

/// One message's coverage-relevant projection.
public struct CoverageSlot: Sendable, Hashable {
	public var message: Message
	public var fp: String
	public var tokens: Int
	public init(message: Message, fp: String, tokens: Int) {
		self.message = message
		self.fp = fp
		self.tokens = tokens
	}
}

/// Fingerprint a whole transcript, in order.
public func coverageSlots(_ messages: [Message]) -> [CoverageSlot] {
	messages.map { CoverageSlot(message: $0, fp: messageFingerprint($0), tokens: viewTokens(messageViewLines($0, mid: $0.id))) }
}

/// The covered-fingerprint set for one chat, from the ledger.
public func coveredSet(_ entries: [CoverageEntry], chatId: String) -> Set<String> {
	Set(entries.filter { $0.chatId == chatId }.map(\.fp))
}

/// The derived coverage state of one transcript.
public struct CoverageState: Sendable, Hashable {
	public var slots: [CoverageSlot]
	/// INDEXES into `slots` (the batcher batches by position).
	public var uncovered: [Int]
	public var coveredTokens: Int
	public var uncoveredTokens: Int
	public var coveredCount: Int
	public var uncoveredCount: Int
}

/// Which slots are uncovered, plus the token totals. Messages with NO view
/// lines are invisible: neither covered nor uncovered.
public func coverageOf(_ messages: [Message], entries: [CoverageEntry], chatId: String) -> CoverageState {
	let covered = coveredSet(entries, chatId: chatId)
	let slots = coverageSlots(messages)
	var uncovered: [Int] = []
	var coveredTokens = 0
	var uncoveredTokens = 0
	var visibleCount = 0
	for (i, slot) in slots.enumerated() {
		if messageViewLines(slot.message, mid: slot.message.id).isEmpty { continue } // invisible
		visibleCount += 1
		if covered.contains(slot.fp) {
			coveredTokens += slot.tokens
		} else {
			uncovered.append(i)
			uncoveredTokens += slot.tokens
		}
	}
	return CoverageState(
		slots: slots,
		uncovered: uncovered,
		coveredTokens: coveredTokens,
		uncoveredTokens: uncoveredTokens,
		coveredCount: visibleCount - uncovered.count,
		uncoveredCount: uncovered.count)
}

/// Batch the uncovered slots into token-budgeted RUNS: consecutive, oldest
/// first, greedy fill — a message is never split; one over-budget message
/// rides alone. A non-positive budget yields no runs.
public func batchRuns(_ slots: [CoverageSlot], uncovered: [Int], budget: Int) -> [[CoverageSlot]] {
	if budget <= 0 || uncovered.isEmpty { return [] }
	var runs: [[CoverageSlot]] = []
	var current: [CoverageSlot] = []
	var currentTokens = 0
	for i in uncovered {
		let slot = slots[i]
		if !current.isEmpty && currentTokens + slot.tokens > budget {
			runs.append(current)
			current = []
			currentTokens = 0
		}
		current.append(slot)
		currentTokens += slot.tokens
	}
	if !current.isEmpty { runs.append(current) }
	return runs
}

/// A batch's deterministic tag: the first 12 hex of sha256 over its member
/// fingerprints in order (the observation-ref prefix — re-running the same
/// batch dedupes; a re-opened member changes the tag).
public func batchTag(_ batch: [CoverageSlot]) -> String {
	var h = SHA256()
	for slot in batch { h.update(data: Data(slot.fp.utf8)) }
	return String(GraphJS.hex(h.finalize()).prefix(12))
}
