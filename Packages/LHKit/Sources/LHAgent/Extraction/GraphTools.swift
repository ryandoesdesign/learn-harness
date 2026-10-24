import Foundation
import LHCore

// Port of src/agent/tools/graph.ts (docs/native-macos-m7.md): the prober's
// map of the persistent graph (list_sessions / list_propositions, names
// only), and the auditor's identity tools (find, list_sessions,
// list_propositions with full statements). Text is TS-identical (the golden
// dump generates GeneratedGraphTools).

/// The graph the tools read, built per call (the stores aren't Sendable).
public struct GraphToolDeps: Sendable {
	public var make: @Sendable () -> GraphDeps
	public init(_ make: @escaping @Sendable () -> GraphDeps) { self.make = make }
}

/// The prober's pair, registered after `pdf` and before `probe_done` while
/// graphToolsEnabled holds.
public func proberGraphTools(_ deps: GraphToolDeps) -> [any AgentTool] {
	[
		GraphTool(name: "list_sessions", description: GeneratedGraphTools.proberListSessionsDescription, schema: GeneratedGraphTools.proberListSessionsSchema) { _ in
			let sessions = graphSessionIndex(deps.make())
			if sessions.isEmpty { return "The knowledge graph is empty — no session has contributed propositions yet." }
			let lines = sessions.enumerated().map { i, s in
				"\(i + 1). \(s.name) (\(s.kind.rawValue), \(s.propositions) proposition\(s.propositions == 1 ? "" : "s"), "
					+ "born \(s.createdAt ?? "unknown date")\(s.updatedAt.map { ", last active \($0)" } ?? "")) — id: \(s.id)"
			}
			return "\(sessions.count) session(s) in the knowledge graph, most recent first:\n\(lines.joined(separator: "\n"))"
		},
		GraphTool(name: "list_propositions", description: GeneratedGraphTools.proberListPropositionsDescription, schema: GeneratedGraphTools.proberListPropositionsSchema) { input in
			let session = input["session"]?.stringValue ?? ""
			let props = graphSessionPropositions(deps.make(), sessionId: session)
			if props.isEmpty { return "No propositions born in session \"\(session)\". Call list_sessions for the current ids." }
			return "\(props.count) proposition(s) covered in this session:\n\(props.map { "- \($0.name)" }.joined(separator: "\n"))"
		},
	]
}

/// The auditor's tools (the identity search).
func auditorGraphTools(_ deps: GraphToolDeps) -> [any AgentTool] {
	[
		GraphTool(name: "find", description: GeneratedGraphTools.auditorFindDescription, schema: GeneratedGraphTools.auditorFindSchema) { input in
			let query = input["query"]?.stringValue ?? ""
			let hits = getGraph(deps.make().graphStore).nodes.filter {
				globMatch(query, $0.name) || globMatch(query, $0.statement) || $0.aliases.contains { globMatch(query, $0) }
			}
			if hits.isEmpty { return "No existing proposition matches \"\(query)\"." }
			let lines = hits.map { n in
				var seen = Set<String>()
				let born = n.provenance.map(\.chatId).filter { seen.insert($0).inserted }
				return "- \(n.id) :: \(n.name)\n  statement: \(n.statement)" + (born.isEmpty ? "" : "\n  born in: \(born.joined(separator: ", "))")
			}
			return "\(hits.count) match(es):\n\(lines.joined(separator: "\n"))"
		},
		GraphTool(name: "list_sessions", description: GeneratedGraphTools.auditorListSessionsDescription, schema: GeneratedGraphTools.auditorListSessionsSchema) { _ in
			let sessions = graphSessionIndex(deps.make())
			if sessions.isEmpty { return "The knowledge graph is empty — no session has contributed propositions yet." }
			let lines = sessions.enumerated().map { i, s in
				"\(i + 1). \(s.name) (\(s.kind.rawValue), \(s.propositions) proposition\(s.propositions == 1 ? "" : "s")) — id: \(s.id)"
			}
			return "\(sessions.count) session(s):\n\(lines.joined(separator: "\n"))"
		},
		GraphTool(name: "list_propositions", description: GeneratedGraphTools.auditorListPropositionsDescription, schema: GeneratedGraphTools.auditorListPropositionsSchema) { input in
			let session = input["session"]?.stringValue ?? ""
			let d = deps.make()
			let props = graphSessionPropositions(d, sessionId: session)
			if props.isEmpty { return "No propositions born in session \"\(session)\". Call list_sessions for the current ids." }
			let nodes = Dictionary(getGraph(d.graphStore).nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
			let lines = props.map { "- \($0.nodeId) :: \($0.name)\n  statement: \(nodes[$0.nodeId]?.statement ?? "(unknown)")" }
			return "\(props.count) proposition(s) born in this session:\n\(lines.joined(separator: "\n"))"
		},
	]
}

/// graph.ts globMatch: case-insensitive, `*` spans anything; a bare term gets implicit `*…*`.
func globMatch(_ pattern: String, _ text: String) -> Bool {
	let raw = pattern.contains("*") ? pattern : "*\(pattern)*"
	let body = raw.split(separator: "*", omittingEmptySubsequences: false).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[\\s\\S]*")
	guard let re = try? NSRegularExpression(pattern: "^\(body)$", options: [.caseInsensitive]) else { return false }
	return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

/// A read-only graph tool: its text result is the whole output.
struct GraphTool: AgentTool {
	let name: String
	let description: String
	let schema: JSONSchema
	let run: @Sendable (JSONValue) -> String

	init(name: String, description: String, schema: JSONSchema, run: @escaping @Sendable (JSONValue) -> String) {
		self.name = name
		self.description = description
		self.schema = schema
		self.run = run
	}

	func execute(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput { .value(.string(run(input))) }
}
