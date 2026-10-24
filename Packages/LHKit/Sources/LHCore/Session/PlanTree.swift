import Foundation

// Port of src/core/plan-tree.ts — pure, validated plan-tree operations
// (vision §2 "the formal plan tree").
//
// Every op returns a NEW tree. Validation throws `PlanTreeError` with a
// message written for the agent (it flows straight back as a tool-result
// error), naming exactly which id/edge is at fault.
//
// Invariants: node ids unique and non-empty; every edge endpoint exists;
// the structure is a DAG (no self-loops, no duplicate edges, no cycles).
// `createTree` always starts at version 1. The per-node mutation ops were
// deleted with the author-once protocol — restructuring is a plan_init
// rewrite.

/// Error thrown by every op on invalid input. `message` is agent-readable.
public struct PlanTreeError: Error, Sendable, Hashable, CustomStringConvertible {
	public var message: String
	public init(_ message: String) { self.message = message }
	public var description: String { message }
}

/// An empty, never-stored tree used as the seed before plan_init runs.
public func emptyTree() -> PlanTree {
	PlanTree(nodes: [], edges: [], version: 0)
}

// MARK: - validation helpers

private func assertValidNode(_ node: PlanNode) throws(PlanTreeError) {
	if node.id.jsTrimmed.isEmpty {
		throw PlanTreeError("Every node needs a non-empty `id` (a stable slug like 'chain-rule-intuition').")
	}
	if node.title.jsTrimmed.isEmpty {
		throw PlanTreeError("Node \"\(node.id)\" needs a non-empty `title`.")
	}
}

private func nodeIdSet(_ nodes: [PlanNode]) throws(PlanTreeError) -> Set<String> {
	var ids = Set<String>()
	for node in nodes {
		try assertValidNode(node)
		if ids.contains(node.id) {
			throw PlanTreeError("Duplicate node id \"\(node.id)\" — node ids must be unique.")
		}
		ids.insert(node.id)
	}
	return ids
}

private func requireNode(_ ids: Set<String>, _ id: String, _ what: String) throws(PlanTreeError) {
	if !ids.contains(id) {
		throw PlanTreeError("\(what) references unknown node id \"\(id)\" — it is not in the tree.")
	}
}

/// Would adding edge from→to create a cycle? Walk forward from `to` along
/// existing edges; reaching `from` means the new edge closes a loop.
private func createsCycle(_ edges: [PlanEdge], _ from: String, _ to: String) -> Bool {
	var adjacency: [String: [String]] = [:]
	for e in edges { adjacency[e.from, default: []].append(e.to) }
	var stack = [to]
	var seen = Set<String>()
	while let current = stack.popLast() {
		if current == from { return true }
		if seen.contains(current) { continue }
		seen.insert(current)
		stack.append(contentsOf: adjacency[current] ?? [])
	}
	return false
}

/// Full edge validation: endpoints exist, no self-loop, no duplicate, acyclic.
private func assertValidEdge(_ from: String, _ to: String, _ nodes: [PlanNode], _ existing: [PlanEdge]) throws(PlanTreeError) {
	let ids = try nodeIdSet(nodes) // also re-validates nodes
	try requireNode(ids, from, "Edge `from`")
	try requireNode(ids, to, "Edge `to`")
	if from == to {
		throw PlanTreeError("Edge \"\(from)\" → \"\(to)\" is a self-loop — a node can't require itself.")
	}
	if existing.contains(where: { $0.from == from && $0.to == to }) {
		throw PlanTreeError("Edge \"\(from)\" → \"\(to)\" already exists — duplicate edges are not allowed.")
	}
	if createsCycle(existing, from, to) {
		throw PlanTreeError(
			"Edge \"\(from)\" → \"\(to)\" would create a cycle: \"\(to)\" already leads (directly or transitively) back to \"\(from)\". "
				+ "\"from\" must be understood before \"to\" — the tree is a DAG.")
	}
}

// MARK: - ops

/// Build a fresh tree (version 1) from node and edge lists, validating all
/// invariants. Each edge is checked against the ones already accepted, so
/// any violation names the culprit edge.
public func createTree(_ nodes: [PlanNode], _ edges: [PlanEdge]) throws(PlanTreeError) -> PlanTree {
	let ids = try nodeIdSet(nodes)
	for e in edges {
		try requireNode(ids, e.from, "Edge `from`")
		try requireNode(ids, e.to, "Edge `to`")
	}
	var accepted: [PlanEdge] = []
	for e in edges {
		try assertValidEdge(e.from, e.to, nodes, accepted)
		accepted.append(PlanEdge(from: e.from, to: e.to))
	}
	return PlanTree(nodes: nodes, edges: accepted, version: 1)
}
