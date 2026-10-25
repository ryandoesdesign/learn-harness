import Foundation

// Port of src/core/contracts/plan.ts — the session-scoped plan tree.

public struct PlanNode: Sendable, Hashable, Codable {
	/// Opaque, agent-chosen slug, stable across edits.
	public var id: String
	public var title: String
	public var summary: String?
	public init(id: String, title: String, summary: String? = nil) {
		self.id = id
		self.title = title
		self.summary = summary
	}
}

public struct PlanEdge: Sendable, Hashable, Codable {
	/// Prerequisite node id.
	public var from: String
	/// Node that depends on `from`.
	public var to: String
	public init(from: String, to: String) {
		self.from = from
		self.to = to
	}
}

public struct PlanTree: Sendable, Hashable, Codable {
	public var nodes: [PlanNode]
	public var edges: [PlanEdge]
	/// Increments on every mutation.
	public var version: Int
	public init(nodes: [PlanNode], edges: [PlanEdge], version: Int) {
		self.nodes = nodes
		self.edges = edges
		self.version = version
	}
}

/// Derived, never stored.
public enum PlanNodeStatus: String, Sendable, Hashable, Codable {
	case current, visited, upcoming
}

public struct DerivedPlanStatuses: Sendable, Hashable {
	/// The node the most recent tagged quiz call is about; nil before any.
	public var current: String?
	/// Nodes referenced by earlier tagged calls.
	public var visited: Set<String>
	public init(current: String?, visited: Set<String>) {
		self.current = current
		self.visited = visited
	}
}

public func derivedNodeStatus(_ statuses: DerivedPlanStatuses, _ nodeId: String) -> PlanNodeStatus {
	if statuses.current == nodeId { return .current }
	if statuses.visited.contains(nodeId) { return .visited }
	return .upcoming
}

/// Position from CALLS, never from results (contracts/plan.ts
/// derivePlanStatusesLh): quiz/explain/ask_user_question calls tagged with a
/// node id of the current tree, consecutive duplicates collapsed.
public func derivePlanStatuses(_ tree: PlanTree, _ messages: [Message]) -> DerivedPlanStatuses {
	let ids = Set(tree.nodes.map(\.id))
	var runs: [String] = []
	for m in messages {
		guard let a = m.assistant else { continue }
		// A tagged ask_user_question (an exercise on a step) moves the map as checks do.
		for call in a.toolUses where call.name == "quiz" || call.name == "explain" || call.name == "ask_user_question" {
			guard let nodeId = call.input["nodeId"]?.stringValue, ids.contains(nodeId) else { continue }
			if runs.last != nodeId { runs.append(nodeId) }
		}
	}
	return DerivedPlanStatuses(current: runs.last, visited: Set(runs.dropLast()))
}

/// The plan tool result: `tree` on success only.
public struct PlanToolResult: Sendable, Hashable, Codable {
	public var ok: Bool
	public var error: String?
	public var tree: PlanTree?
	public init(ok: Bool, error: String? = nil, tree: PlanTree? = nil) {
		self.ok = ok
		self.error = error
		self.tree = tree
	}
}
