import Foundation
import Testing
@testable import LHCore

/// Test fixtures: the repo's golden data dir (read in place — one source of
/// truth with the TS suite) and the TS golden dumps (Golden/*.json, written
/// by scripts/dump-core-golden.ts).
enum Fixtures {
	static let repoRoot: URL = {
		// …/Packages/LHKit/Tests/LHCoreTests/Support/GoldenSupport.swift
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<6 { url.deleteLastPathComponent() }
		return url
	}()

	static let goldenData = repoRoot.appending(path: "tests/fixtures/golden-data")

	static let teachChatId = "chat_mv27rrra_feff23b6"
	static let practiceChatId = "chat_mv293wv5_10656952"

	static func json(_ relative: String) throws -> JSONValue {
		try JSONValue.parse(Data(contentsOf: goldenData.appending(path: relative)))
	}

	/// JSONL ledger lines, parsed.
	static func jsonl(_ relative: String) throws -> [JSONValue] {
		let text = try String(contentsOf: goldenData.appending(path: relative), encoding: .utf8)
		return try text.split(separator: "\n", omittingEmptySubsequences: true).map { try JSONValue.parse(String($0)) }
	}

	/// A golden chat, converted to the native record.
	static func chat(_ id: String) throws -> ChatRecord {
		let raw = try json("chats/\(id).json")
		return try #require(ChatRecord(legacyJSON: raw))
	}

	static var teachChat: ChatRecord { get throws { try chat(teachChatId) } }
	static var practiceChat: ChatRecord { get throws { try chat(practiceChatId) } }
}

enum Golden {
	/// A TS dump: Golden/<name>.json.
	static func load(_ name: String) throws -> JSONValue {
		guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Golden") else {
			throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Golden/\(name).json"])
		}
		return try JSONValue.parse(Data(contentsOf: url))
	}
}

/// Structural JSON comparison: object key ORDER is ignored, numbers compare
/// within `tolerance` (relative for large magnitudes). Returns the first
/// differing path, or nil when equal.
func jsonDiff(_ a: JSONValue, _ b: JSONValue, tolerance: Double = 0, path: String = "$") -> String? {
	switch (a, b) {
	case (.null, .null): return nil
	case (.bool(let x), .bool(let y)): return x == y ? nil : "\(path): \(x) ≠ \(y)"
	case (.string(let x), .string(let y)): return x == y ? nil : "\(path): \(JSONValue.quote(x).prefix(200)) ≠ \(JSONValue.quote(y).prefix(200))"
	case (.number(let x), .number(let y)):
		let dx = x.double, dy = y.double
		if dx == dy { return nil }
		let scale = Swift.max(1, Swift.max(abs(dx), abs(dy)))
		return abs(dx - dy) <= tolerance * scale ? nil : "\(path): \(x.lexeme) ≠ \(y.lexeme)"
	case (.array(let x), .array(let y)):
		if x.count != y.count { return "\(path): array length \(x.count) ≠ \(y.count)" }
		for i in x.indices {
			if let d = jsonDiff(x[i], y[i], tolerance: tolerance, path: "\(path)[\(i)]") { return d }
		}
		return nil
	case (.object(let x), .object(let y)):
		let kx = Set(x.keys), ky = Set(y.keys)
		if kx != ky { return "\(path): keys differ — only left: \(kx.subtracting(ky).sorted()), only right: \(ky.subtracting(kx).sorted())" }
		for k in x.keys {
			if let d = jsonDiff(x[k]!, y[k]!, tolerance: tolerance, path: "\(path).\(k)") { return d }
		}
		return nil
	default:
		return "\(path): type mismatch \(a.serialized().prefix(120)) vs \(b.serialized().prefix(120))"
	}
}

/// `#expect` that two JSON values are structurally equal.
func expectJSONEqual(_ actual: JSONValue, _ expected: JSONValue, tolerance: Double = 0, sourceLocation: SourceLocation = #_sourceLocation) {
	let d = jsonDiff(actual, expected, tolerance: tolerance)
	#expect(d == nil, "\(d ?? "")", sourceLocation: sourceLocation)
}
