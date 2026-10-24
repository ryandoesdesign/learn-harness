import Foundation

// Port of agent/tools/mermaid-plan.ts — the plan_init authoring format: a
// hand-parsed mermaid subset with line-numbered problems the teacher can
// act on. THE ONE STRICT RULE: node ids are permanent lowercase slugs.

public struct ParsedPlan: Sendable, Hashable {
	public var nodes: [PlanNode]
	public var edges: [PlanEdge]
}

public struct PlanParseResult: Sendable, Hashable {
	public var ok: Bool
	/// All problems, each prefixed with its 1-based line number.
	public var problems: [String]
	public var plan: ParsedPlan?
}

nonisolated(unsafe) private let headerRe = /(?i)^(graph|flowchart)\s+(td|tb|lr|rl|bt)\s*$/
nonisolated(unsafe) private let slugRe = /^[a-z0-9]+([_-][a-z0-9]+)*$/
nonisolated(unsafe) private let arrowRe = /-->|==>|-\.->/
nonisolated(unsafe) private let endpointRe = /^([^\s()\[\]]+)\s*(?:\[([^\[\]]*)\]|\(\s*"([^"]*)"\s*\)|\(([^()]*)\))?$/

private struct Endpoint {
	var id: String
	var label: String
}

private func parseEndpoint(_ text: String) -> Endpoint? {
	guard let m = text.jsTrimmed.wholeMatch(of: endpointRe) else { return nil }
	var label = String(m.2 ?? m.3 ?? m.4 ?? "").jsTrimmed
	if label.jsLength >= 2, (label.hasPrefix("\"") && label.hasSuffix("\"")) || (label.hasPrefix("'") && label.hasSuffix("'")) {
		label = label.jsSlice(1, -1).jsTrimmed
	}
	return Endpoint(id: String(m.1), label: label)
}

/// Parse the mermaid subset. Collects ALL problems (never just the first).
public func parseMermaidPlan(_ mermaid: String) -> PlanParseResult {
	var problems: [String] = []
	let lines = mermaid.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
		line.hasSuffix("\r") ? String(line.dropLast()) : String(line)
	}
	guard let first = lines.firstIndex(where: { !$0.jsTrimmed.isEmpty && !$0.jsTrimmed.hasPrefix("%%") }) else {
		return PlanParseResult(ok: false, problems: ["The plan is empty — expected a `graph TD` block with nodes and `-->` requires-edges."], plan: nil)
	}
	let header = lines[first].jsTrimmed
	if header.wholeMatch(of: headerRe) == nil {
		problems.append("line \(first + 1): expected the header `graph TD` (or flowchart TD/TB) first, got `\(header)`.")
	}

	var order: [String] = []
	var nodes: [String: String] = [:]
	var edges: [PlanEdge] = []
	var seen = Set<String>()

	func register(_ ep: Endpoint, _ lineNo: Int) {
		guard ep.id.wholeMatch(of: slugRe) != nil else {
			problems.append("line \(lineNo): node id `\(ep.id)` must be a lowercase slug (a-z, 0-9, joined by hyphens or underscores — e.g. `chain-rule-intuition`); ids are permanent and checks reference them.")
			return
		}
		if nodes[ep.id] == nil {
			order.append(ep.id)
			nodes[ep.id] = ep.label.isEmpty ? ep.id : ep.label
		} else if !ep.label.isEmpty, nodes[ep.id] == ep.id {
			nodes[ep.id] = ep.label
		}
	}

	for i in (first + 1)..<lines.count {
		let line = lines[i].jsTrimmed
		let no = i + 1
		if line.isEmpty || line.hasPrefix("%%") { continue }
		let segments = line.split(separator: arrowRe, omittingEmptySubsequences: false).map(String.init)
		if segments.count >= 2 {
			var endpoints: [Endpoint] = []
			var unreadable = false
			for seg in segments {
				guard let ep = parseEndpoint(seg) else {
					problems.append("line \(no): can't read the edge `\(line)` — expected `a[title] --> b[title]` (chains like `a --> b --> c` are fine).")
					unreadable = true
					break
				}
				endpoints.append(ep)
			}
			if !unreadable {
				for ep in endpoints { register(ep, no) }
				for k in 0..<(endpoints.count - 1) {
					let from = endpoints[k], to = endpoints[k + 1]
					if from.id == to.id {
						problems.append("line \(no): self-loop `\(from.id) --> \(to.id)` — a node can't require itself.")
						continue
					}
					if seen.insert("\(from.id)->\(to.id)").inserted { edges.append(PlanEdge(from: from.id, to: to.id)) }
				}
			}
		} else {
			guard let node = parseEndpoint(line) else {
				problems.append("line \(no): can't parse `\(line)` — ids are the strict part (lowercase slugs: a-z, 0-9, hyphens, underscores); node lines (`slug[title]`) and requires-edges (`a --> b`) are the accepted forms; subgraphs, styles, and classes are not part of the subset.")
				continue
			}
			register(node, no)
		}
	}

	if !problems.isEmpty { return PlanParseResult(ok: false, problems: problems, plan: nil) }
	if order.isEmpty { return PlanParseResult(ok: false, problems: ["No nodes found — the plan needs at least one."], plan: nil) }
	return PlanParseResult(ok: true, problems: [], plan: ParsedPlan(nodes: order.map { PlanNode(id: $0, title: nodes[$0]!) }, edges: edges))
}
