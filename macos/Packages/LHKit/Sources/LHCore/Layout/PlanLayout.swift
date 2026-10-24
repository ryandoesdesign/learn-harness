import Foundation

// The plan DAG's placement — a native layered (Sugiyama-style) layout that
// replaces the TS app's dagre (docs/native-macos-m4.md): longest-path
// ranks, dummy nodes for long edges, barycentric ordering sweeps, and a
// neighbor-averaging coordinate pass. The node sizing (text-first boxes)
// and wrapping are ported verbatim from components/plan-block.tsx.
// Deterministic, synchronous and pure.

/// Symmetric horizontal padding inside a node box.
public let PLAN_PAD_X = 16.0
public let PLAN_NODE_W_MIN = 96.0
public let PLAN_NODE_H = 44.0
/// Baseline-to-baseline distance of node titles.
public let PLAN_LINE_H = 13.0
public let PLAN_GAP_X = 24.0
public let PLAN_GAP_Y = 48.0
/// Padding around the layout extent so centered strokes never clip.
public let PLAN_GRAPH_PAD = 8.0
/// The current node's glow reach (margin + 3σ of the blur).
public let PLAN_GLOW_MARGIN = 8.0
public let PLAN_GLOW_BLUR = 5.0
public let PLAN_GLOW_REACH = PLAN_GLOW_MARGIN + 3 * PLAN_GLOW_BLUR
/// The in-chat block never renders node text past the prose size.
public let PLAN_TEXT_CAP_SCALE = 16.0 / 12.5

private let narrowChars = Set(" ijltfr.,:;'!|()[]-\\".unicodeScalars)
private let wideChars = Set("mwMW@".unicodeScalars)

/// Estimated rendered width of one title line (per-character-class rates).
public func estimateLineWidth(_ line: String) -> Double {
	var w = 0.0
	for ch in line.unicodeScalars {
		if narrowChars.contains(ch) { w += 3.1 }
		else if wideChars.contains(ch) { w += 9.2 }
		else if ("A"..."Z").contains(ch) || ("0"..."9").contains(ch) { w += 6.0 }
		else { w += 5.4 }
	}
	return w
}

/// Greedy word wrap to lines of ≤ maxChars (UTF-16 length, as JS); an
/// oversized word is hard-chunked so nothing is lost.
public func wrapTitle(_ title: String, maxChars: Int = 28) -> [String] {
	let words = title.jsTrimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
	if words.isEmpty { return [""] }
	var atoms: [String] = []
	for w in words {
		var i = 0
		while i < w.jsLength {
			atoms.append(w.jsSlice(i, i + maxChars))
			i += maxChars
		}
	}
	var lines: [String] = []
	for a in atoms {
		if let last = lines.last, last.jsLength + 1 + a.jsLength <= maxChars {
			lines[lines.count - 1] = "\(last) \(a)"
		} else {
			lines.append(a)
		}
	}
	return lines
}

/// A node's box width for its wrapped lines.
public func planNodeWidth(_ lines: [String]) -> Double {
	let widest = max(1, lines.map(estimateLineWidth).max() ?? 1)
	return max(PLAN_NODE_W_MIN, widest.rounded(.up) + 2 * PLAN_PAD_X)
}

public struct PlanLayoutNode: Sendable, Hashable {
	public var id: String
	public var title: String
	public init(id: String, title: String) {
		self.id = id
		self.title = title
	}
}

public struct PlanLayoutPoint: Sendable, Hashable {
	public var x: Double
	public var y: Double
	public init(x: Double, y: Double) {
		self.x = x
		self.y = y
	}
}

/// A placed node: top-left origin, size, wrapped lines.
public struct PlacedPlanNode: Sendable, Hashable {
	public var id: String
	public var x: Double
	public var y: Double
	public var w: Double
	public var h: Double
	public var lines: [String]
	public var rank: Int
}

public struct PlacedPlanEdge: Sendable, Hashable {
	public var from: String
	public var to: String
	/// Source bottom-center, dummy waypoints, target top-center.
	public var points: [PlanLayoutPoint]
}

public struct PlanLayoutResult: Sendable, Hashable {
	public var nodes: [PlacedPlanNode]
	public var edges: [PlacedPlanEdge]
	public var width: Double
	public var height: Double
	public func node(_ id: String) -> PlacedPlanNode? { nodes.first { $0.id == id } }
}

/// Topological order + longest-path depth (Kahn, authoring-order
/// tie-break; nodes on a cycle land at depth 0 after the rest).
public func planTopo(_ nodes: [PlanLayoutNode], _ edges: [PlanEdge]) -> (order: [String], depth: [String: Int]) {
	let index = Dictionary(nodes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
	var indegree = Dictionary(nodes.map { ($0.id, 0) }, uniquingKeysWith: { a, _ in a })
	var dependents: [String: [String]] = [:]
	for e in edges where index[e.from] != nil && index[e.to] != nil {
		indegree[e.to, default: 0] += 1
		dependents[e.from, default: []].append(e.to)
	}
	var ready = nodes.filter { indegree[$0.id] == 0 }.map(\.id)
	var order: [String] = []
	var depth: [String: Int] = [:]
	while !ready.isEmpty {
		ready.sort { index[$0, default: 0] < index[$1, default: 0] }
		let id = ready.removeFirst()
		order.append(id)
		let d = depth[id] ?? 0
		depth[id] = d
		for t in dependents[id] ?? [] {
			if (depth[t] ?? -1) < d + 1 { depth[t] = d + 1 }
			indegree[t, default: 0] -= 1
			if indegree[t] == 0 { ready.append(t) }
		}
	}
	for n in nodes where !order.contains(n.id) {
		order.append(n.id)
		depth[n.id] = 0
	}
	return (order, depth)
}

/// Lay the plan out top-to-bottom. Edges with a missing endpoint, and
/// edges that don't point down a rank (cycles), are not routed.
public func planLayout(_ nodes: [PlanLayoutNode], _ edges: [PlanEdge]) -> PlanLayoutResult {
	guard !nodes.isEmpty else { return PlanLayoutResult(nodes: [], edges: [], width: 0, height: 0) }
	var seen = Set<String>()
	let nodes = nodes.filter { seen.insert($0.id).inserted }
	let (order, depth) = planTopo(nodes, edges)
	let titles = Dictionary(nodes.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })

	// Layer slots: real nodes plus one dummy per intermediate rank of a long edge.
	struct Slot {
		var key: String
		var w: Double
		var isDummy: Bool
	}
	let rankCount = (depth.values.max() ?? 0) + 1
	var layers: [[Slot]] = Array(repeating: [], count: rankCount)
	var lines: [String: [String]] = [:]
	var heights: [String: Double] = [:]
	for id in order {
		let l = wrapTitle(titles[id] ?? "")
		lines[id] = l
		heights[id] = PLAN_NODE_H + Double(max(0, l.count - 2)) * PLAN_LINE_H
		layers[depth[id] ?? 0].append(Slot(key: id, w: planNodeWidth(l), isDummy: false))
	}
	var routed: [(edge: PlanEdge, chain: [String])] = []
	var routedKeys = Set<String>()
	for e in edges {
		guard let a = depth[e.from], let b = depth[e.to], titles[e.from] != nil, titles[e.to] != nil, b > a else { continue }
		guard routedKeys.insert("\(e.from)->\(e.to)").inserted else { continue }
		var chain = [e.from]
		for r in (a + 1)..<b {
			let key = "\u{0}\(e.from)->\(e.to)#\(r)"
			layers[r].append(Slot(key: key, w: 0, isDummy: true))
			chain.append(key)
		}
		chain.append(e.to)
		routed.append((e, chain))
	}

	// Adjacency between consecutive layers (via the chains).
	var up: [String: [String]] = [:]
	var down: [String: [String]] = [:]
	for (_, chain) in routed {
		for i in 0..<(chain.count - 1) {
			down[chain[i], default: []].append(chain[i + 1])
			up[chain[i + 1], default: []].append(chain[i])
		}
	}

	// Ordering: barycentric sweeps (down, then up), stable on ties.
	func positions(_ layer: [Slot]) -> [String: Double] {
		Dictionary(layer.enumerated().map { ($1.key, Double($0)) }, uniquingKeysWith: { a, _ in a })
	}
	func reorder(_ r: Int, by neighbors: [String: [String]], in ref: [Slot]) {
		let pos = positions(ref)
		let current = positions(layers[r])
		let keyed = layers[r].map { slot -> (Slot, Double) in
			let ns = (neighbors[slot.key] ?? []).compactMap { pos[$0] }
			let bary = ns.isEmpty ? current[slot.key]! : ns.reduce(0, +) / Double(ns.count)
			return (slot, bary)
		}
		layers[r] = keyed.enumerated().sorted { a, b in
			a.element.1 != b.element.1 ? a.element.1 < b.element.1 : a.offset < b.offset
		}.map(\.element.0)
	}
	for _ in 0..<4 {
		if rankCount > 1 { for r in 1..<rankCount { reorder(r, by: up, in: layers[r - 1]) } }
		if rankCount > 1 { for r in stride(from: rankCount - 2, through: 0, by: -1) { reorder(r, by: down, in: layers[r + 1]) } }
	}

	// Coordinates: pack each layer, then pull nodes toward their neighbors'
	// mean center while keeping order and GAP_X separation.
	var cx: [String: Double] = [:]
	var widths: [String: Double] = [:]
	for layer in layers {
		var x = 0.0
		for slot in layer {
			widths[slot.key] = slot.w
			cx[slot.key] = x + slot.w / 2
			x += slot.w + PLAN_GAP_X
		}
	}
	func settle(_ r: Int, toward neighbors: [String: [String]]) {
		let layer = layers[r]
		var desired = layer.map { slot -> Double in
			let ns = (neighbors[slot.key] ?? []).compactMap { cx[$0] }
			return ns.isEmpty ? cx[slot.key]! : ns.reduce(0, +) / Double(ns.count)
		}
		// Left-to-right: enforce separation from the previous slot.
		for i in layer.indices.dropFirst() {
			let minC = desired[i - 1] + layer[i - 1].w / 2 + PLAN_GAP_X + layer[i].w / 2
			if desired[i] < minC { desired[i] = minC }
		}
		// Shift the run back by the mean overshoot so the layer stays centered on its targets.
		let original = layer.map { slot -> Double in
			let ns = (neighbors[slot.key] ?? []).compactMap { cx[$0] }
			return ns.isEmpty ? cx[slot.key]! : ns.reduce(0, +) / Double(ns.count)
		}
		let drift = zip(desired, original).map { $0 - $1 }.reduce(0, +) / Double(max(layer.count, 1))
		for (i, slot) in layer.enumerated() { cx[slot.key] = desired[i] - drift }
	}
	for _ in 0..<8 {
		if rankCount > 1 { for r in 1..<rankCount { settle(r, toward: up) } }
		if rankCount > 1 { for r in stride(from: rankCount - 2, through: 0, by: -1) { settle(r, toward: down) } }
	}

	// Ranks top to bottom; each rank as tall as its tallest node.
	var rankY: [Double] = []
	var y = 0.0
	for layer in layers {
		rankY.append(y)
		let h = layer.filter { !$0.isDummy }.compactMap { heights[$0.key] }.max() ?? 0
		y += h + PLAN_GAP_Y
	}
	let rankH = layers.map { layer in layer.filter { !$0.isDummy }.compactMap { heights[$0.key] }.max() ?? 0 }

	// Normalize so the extent starts at 0.
	let minX = layers.flatMap { $0 }.map { cx[$0.key]! - $0.w / 2 }.min() ?? 0
	var placed: [PlacedPlanNode] = []
	for id in order {
		let r = depth[id] ?? 0
		let w = widths[id] ?? PLAN_NODE_W_MIN
		let h = heights[id] ?? PLAN_NODE_H
		placed.append(PlacedPlanNode(id: id, x: cx[id]! - w / 2 - minX, y: rankY[r] + (rankH[r] - h) / 2, w: w, h: h, lines: lines[id] ?? [""], rank: r))
	}
	let byId = Dictionary(placed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
	var placedEdges: [PlacedPlanEdge] = []
	for (e, chain) in routed {
		guard let s = byId[e.from], let t = byId[e.to] else { continue }
		var pts = [PlanLayoutPoint(x: s.x + s.w / 2, y: s.y + s.h)]
		for key in chain.dropFirst().dropLast() {
			let r = Int(key.split(separator: "#").last!)!
			pts.append(PlanLayoutPoint(x: cx[key]! - minX, y: rankY[r] + rankH[r] / 2))
		}
		pts.append(PlanLayoutPoint(x: t.x + t.w / 2, y: t.y))
		placedEdges.append(PlacedPlanEdge(from: e.from, to: e.to, points: pts))
	}
	let width = max(1, placed.map { $0.x + $0.w }.max() ?? 1)
	let height = max(1, y - PLAN_GAP_Y)
	return PlanLayoutResult(nodes: placed, edges: placedEdges, width: width, height: height)
}
