import Foundation
import LHCore
import LHResources

/// The agents whose system prompts compose from segments.
public enum PromptAgent: String, Sendable, Hashable, CaseIterable {
	case prober, teacher, practice
}

/// Port of agent/prompt-segments.ts + teacher-agent.ts composeInstructions,
/// plus the native tool gates (docs/native-macos-m5.md): segments in order
/// (the base, the agent's own `NN-*.md` sorted, then `shared/` sorted —
/// practice: its own dir and a curated shared subset, no base); a segment
/// whose switch is on AND has an override composes the override; trimmed,
/// empties dropped, joined with `\n\n---\n\n`. Gates drop segments or lines
/// that describe tools this build does not register.
public struct PromptComposer: Sendable {
	/// segment path → override body (the prompt_override rows).
	public var overrides: [String: String]
	/// agent.prompts: segment path → switch (absent = off).
	public var switches: [String: Bool]

	public init(overrides: [String: String] = [:], switches: [String: Bool] = [:]) {
		self.overrides = overrides
		self.switches = switches
	}

	static let practiceShared = ["10-voice.md", "15-accuracy.md", "16-mental-model.md", "40-formatting.md"]

	/// The segment paths in composition order (listSourceSegments).
	public static func segmentPaths(_ agent: PromptAgent) -> [String] {
		var out = agent == .practice ? [] : ["system-prompt.md"]
		out += LHResources.promptFragments(agent.rawValue).filter(isFragment).map { "\(agent.rawValue)/\($0)" }
		let shared = LHResources.promptFragments("shared").filter(isFragment)
		out += shared.filter { agent != .practice || practiceShared.contains($0) }.map { "shared/\($0)" }
		return out
	}

	/// FRAGMENT_RE `^\d+-[\w.-]+\.md$`.
	static func isFragment(_ name: String) -> Bool {
		name.wholeMatch(of: /\d+-[A-Za-z0-9_.\-]+\.md/) != nil
	}

	/// The composed system prompt. `tools` = the names registered for this
	/// agent; nil composes without gates (the TS source composition).
	public func compose(_ agent: PromptAgent, tools: Set<String>?) -> String {
		let gates = tools.map { registered in Self.gates.filter { !registered.contains($0.tool) } } ?? []
		return Self.segmentPaths(agent).compactMap { path -> String? in
			if gates.contains(where: { $0.segment == path && $0.prefix == nil }) { return nil }
			var text = switches[path] == true ? (overrides[path] ?? source(path)) : source(path)
			let lineGates = gates.filter { $0.segment == path && $0.prefix != nil }
			if !lineGates.isEmpty { text = Self.dropLines(text, prefixes: lineGates.compactMap(\.prefix)) }
			return text
		}
		.map { $0.jsTrimmed }
		.filter { !$0.isEmpty }
		.joined(separator: "\n\n---\n\n")
	}

	func source(_ path: String) -> String { LHResources.promptSegment(path) ?? "" }

	/// Drop every line whose trimmed text starts with a prefix, then
	/// collapse the blank-line runs the removal leaves to one blank line.
	static func dropLines(_ text: String, prefixes: [String]) -> String {
		let kept = text.components(separatedBy: "\n").filter { line in
			let t = line.trimmingCharacters(in: .whitespaces)
			return !prefixes.contains { t.hasPrefix($0) }
		}
		var out: [String] = []
		for line in kept {
			if line.trimmingCharacters(in: .whitespaces).isEmpty, out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { continue }
			out.append(line)
		}
		return out.joined(separator: "\n")
	}

	struct Gate: Decodable {
		var segment: String
		var prefix: String?
		var tool: String
	}

	static let gates: [Gate] = {
		struct File: Decodable { var gates: [Gate] }
		guard let data = try? LHResources.promptGatesJSON, let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
		return file.gates
	}()
}
