import Foundation

// Port of src/core/layout.ts — the layout engine (d3-force everywhere). One
// force set owns the equilibrium: the merge-time incremental settle and the
// live drag physics run the same forces (link springs, charge repulsion,
// weak gravity, optional cluster pull and inference-depth anchoring).
// Deterministic: seeds derive from node ids, and the d3 port is exact.

/// Link input: edges are undirected for layout purposes.
public typealias LayoutEdge = GraphEdge

/// How the inference rank is expressed spatially: `vertical` = levels are
/// rows (arrows point up), `radial` = levels are rings (foundations at the
/// centre), `off` = free layout.
public enum DepthAnchorMode: String, Sendable, Hashable, Codable {
	case off
	case vertical
	case radial
}

public struct DepthAnchor: Sendable, Hashable {
	public var mode: DepthAnchorMode
	/// Anchor pull toward the level (same units as the cluster pull).
	public var strength: Double
	/// Distance between consecutive inference levels (world units).
	public var spacing: Double
	/// Vertical: `.y` is the depth-0 line; radial: the ring centre. Default (0,0).
	public var center: Position?
	/// Inner ring radius (radial only; depth-0 nodes sit on it).
	public var baseRadius: Double?

	public init(mode: DepthAnchorMode, strength: Double, spacing: Double, center: Position? = nil, baseRadius: Double? = nil) {
		self.mode = mode
		self.strength = strength
		self.spacing = spacing
		self.center = center
		self.baseRadius = baseRadius
	}
}

/// Centre-of-mass gravity (d3 forceX/forceY, mode-projected under depth anchoring).
public struct LayoutGravity: Sendable, Hashable {
	public var x: Double
	public var y: Double
	public var strength: Double
	public init(x: Double, y: Double, strength: Double) {
		self.x = x
		self.y = y
		self.strength = strength
	}
}

/// Cluster centroid pull: the partition (member id lists, Louvain output
/// shape) and its strength (0 = off).
public struct ClusterPull: Sendable, Hashable {
	public var clusters: [[String]]
	public var strength: Double
	public init(clusters: [[String]], strength: Double) {
		self.clusters = clusters
		self.strength = strength
	}
}

public struct SimOptions: Sendable, Hashable {
	/// Link spring rest length (default LINK_DISTANCE).
	public var linkDistance: Double?
	/// Link stiffness multiplier (1 = d3's default 1/min(degree)).
	public var linkStrength: Double?
	/// Many-body repulsion strength (negative; default CHARGE_STRENGTH).
	public var chargeStrength: Double?
	public var gravity: LayoutGravity?
	/// Alpha decay per tick (default 0.0228, ~300 ticks).
	public var alphaDecay: Double?
	/// Velocity damping per tick (default 0.4).
	public var velocityDecay: Double?
	public var depthAnchor: DepthAnchor?
	/// The logical edge list for the depth machinery (default: `edges`).
	/// Springs always run over `edges`.
	public var logicalEdges: [LayoutEdge]?
	/// Imp chain linkage, for the imp midpoint anchor.
	public var impLinks: [ImpLink]?
	public var clusterPull: ClusterPull?

	public init(
		linkDistance: Double? = nil,
		linkStrength: Double? = nil,
		chargeStrength: Double? = nil,
		gravity: LayoutGravity? = nil,
		alphaDecay: Double? = nil,
		velocityDecay: Double? = nil,
		depthAnchor: DepthAnchor? = nil,
		logicalEdges: [LayoutEdge]? = nil,
		impLinks: [ImpLink]? = nil,
		clusterPull: ClusterPull? = nil,
	) {
		self.linkDistance = linkDistance
		self.linkStrength = linkStrength
		self.chargeStrength = chargeStrength
		self.gravity = gravity
		self.alphaDecay = alphaDecay
		self.velocityDecay = velocityDecay
		self.depthAnchor = depthAnchor
		self.logicalEdges = logicalEdges
		self.impLinks = impLinks
		self.clusterPull = clusterPull
	}
}

public let LINK_DISTANCE = 40.0
public let CHARGE_STRENGTH = -240.0
/// The live sim reuses this so its rest state matches the settle's.
public let INCREMENTAL_GRAVITY = 0.12
/// Default cluster-centroid pull strength.
public let CLUSTER_PULL_STRENGTH = 0.15

/// Implication-node id prefix: links touching one get half the rest length.
private let IMP_ID_PREFIX = "arg_"
/// JS `startsWith` (UTF-16 units, no Unicode canonical equivalence).
private func isImpId(_ id: String) -> Bool { id.utf16.starts(with: IMP_ID_PREFIX.utf16) }
/// Per-tick anchor re-blend: the fraction of an anchored node's displacement
/// that survives each tick (position space, alpha-independent).
private let ANCHOR_RETENTION = 0.85
private let BOOTSTRAP_GRAVITY = 0.2

// MARK: - inferenceDepths

/// Inference depth per node: the longest chain of directed edges from a base
/// node. Cycle-safe: iterative Tarjan SCC condensation, and every cycle
/// member shares its component's depth.
public func inferenceDepths(nodeIds: [String], edges: [LayoutEdge]) -> [String: Int] {
	let valid = Set(nodeIds)
	// Insertion-ordered `valid` (the JS Set iteration order).
	var order: [String] = []
	var seenOrder = Set<String>()
	for id in nodeIds where seenOrder.insert(id).inserted { order.append(id) }
	var adj: [String: [String]] = [:]
	for e in edges {
		if e.from == e.to || !valid.contains(e.from) || !valid.contains(e.to) { continue }
		adj[e.from, default: []].append(e.to)
	}

	var num: [String: Int] = [:]
	var low: [String: Int] = [:]
	var onStack = Set<String>()
	var stack: [String] = []
	var comp: [String: Int] = [:]
	var counter = 0
	var compCount = 0
	for start in order {
		if num[start] != nil { continue }
		num[start] = counter
		low[start] = counter
		counter += 1
		stack.append(start)
		onStack.insert(start)
		var work: [(String, Int)] = [(start, 0)]
		while !work.isEmpty {
			let (v, i) = work[work.count - 1]
			let outs = adj[v] ?? []
			if i < outs.count {
				work[work.count - 1].1 = i + 1
				let w = outs[i]
				if num[w] == nil {
					num[w] = counter
					low[w] = counter
					counter += 1
					stack.append(w)
					onStack.insert(w)
					work.append((w, 0))
				} else if onStack.contains(w) {
					low[v] = Swift.min(low[v]!, num[w]!)
				}
			} else {
				work.removeLast()
				if low[v] == num[v] {
					var w: String
					repeat {
						w = stack.removeLast()
						onStack.remove(w)
						comp[w] = compCount
					} while w != v
					compCount += 1
				}
				if let parent = work.last?.0 {
					low[parent] = Swift.min(low[parent]!, low[v]!)
				}
			}
		}
	}

	// Condensation predecessors, then longest path (descending component
	// index is topological order, sources first).
	var preds = [Set<Int>](repeating: [], count: compCount)
	for e in edges {
		guard let a = comp[e.from], let b = comp[e.to], a != b else { continue }
		preds[b].insert(a)
	}
	var depth = [Int](repeating: 0, count: compCount)
	var c = compCount - 1
	while c >= 0 {
		var d = 0
		for p in preds[c] { d = Swift.max(d, depth[p] + 1) }
		depth[c] = d
		c -= 1
	}
	var out: [String: Int] = [:]
	for id in nodeIds { out[id] = comp[id].map { depth[$0] } ?? 0 }
	return out
}

public func inferenceDepths(_ nodes: [GraphNode], edges: [LayoutEdge]) -> [String: Int] {
	inferenceDepths(nodeIds: nodes.map(\.id), edges: edges)
}

// MARK: - The simulation

/// The one force set, as a value: callers drive it with `tick()` (per frame
/// live, or a bounded loop when settling). No timer, no UI; safe to run off
/// the main thread.
public struct GraphSimulation: Sendable {
	/// The simulated nodes, in input order. Per-node state (position,
	/// velocity, fx/fy pins) may be edited between ticks; adding, removing
	/// or reordering nodes is not supported (forces index by position).
	public var nodes: [LayoutNode]
	var core = D3SimulationCore()
	var forces: [LayoutForce] = []

	public var alpha: Double {
		get { core.alpha }
		set { core.alpha = newValue }
	}
	public var alphaMin: Double {
		get { core.alphaMin }
		set { core.alphaMin = newValue }
	}
	public var alphaTarget: Double {
		get { core.alphaTarget }
		set { core.alphaTarget = newValue }
	}
	public var alphaDecay: Double {
		get { core.alphaDecay }
		set { core.alphaDecay = newValue }
	}
	/// d3's `velocityDecay` (the friction; stored internally as 1 − it).
	public var velocityDecay: Double {
		get { 1 - core.velocityDecayFactor }
		set { core.velocityDecayFactor = 1 - newValue }
	}

	/// d3's `simulation.tick(iterations)`.
	public mutating func tick(_ iterations: Int = 1) {
		for _ in 0..<iterations {
			let alpha = core.stepAlpha()
			for force in forces {
				force.apply(&nodes, alpha: alpha, random: &core.random)
			}
			core.integrate(&nodes)
		}
	}
}

/// One registered force, in d3's registration order.
enum LayoutForce: Sendable {
	case link(D3LinkForce)
	case manyBody(D3ManyBodyForce)
	case position(D3PositionForce)
	/// Gravity under depth anchoring: vertical = x-only for every node;
	/// radial = full pull for orphans only.
	case projectedGravity(mode: DepthAnchorMode, gravity: LayoutGravity, orphan: [Bool])
	case clusterPull(ClusterPullForce)
	case depthVertical(depths: [Double], orphan: [Bool]?, baseY: Double, spacing: Double, strength: Double)
	case depthRadial(depths: [Double], orphan: [Bool]?, center: Position, baseRadius: Double, spacing: Double, strength: Double)

	func apply(_ nodes: inout [LayoutNode], alpha: Double, random: inout D3LCG) {
		switch self {
		case .link(let f): f.apply(&nodes, alpha: alpha, random: &random)
		case .manyBody(let f): f.apply(&nodes, alpha: alpha, random: &random)
		case .position(let f): f.apply(&nodes, alpha: alpha)
		case .projectedGravity(let mode, let g, let orphan):
			for i in nodes.indices {
				if mode == .vertical {
					nodes[i].vx = nodes[i].vx + (g.x - nodes[i].x) * g.strength * alpha
				} else if orphan[i] {
					nodes[i].vx = nodes[i].vx + (g.x - nodes[i].x) * g.strength * alpha
					nodes[i].vy = nodes[i].vy + (g.y - nodes[i].y) * g.strength * alpha
				}
			}
		case .clusterPull(let f): f.apply(&nodes, alpha: alpha)
		case .depthVertical(let depths, let orphan, let baseY, let spacing, let strength):
			for i in nodes.indices {
				if orphan?[i] == true { continue }
				let targetY = baseY - depths[i] * spacing
				nodes[i].vy = nodes[i].vy + (targetY - nodes[i].y) * strength * alpha
			}
		case .depthRadial(let depths, let orphan, let center, let baseR, let spacing, let strength):
			for i in nodes.indices {
				if orphan?[i] == true { continue }
				let dx = nodes[i].x - center.x
				let dy = nodes[i].y - center.y
				let r = JSMath.hypot(dx, dy)
				let ux = r > 1e-9 ? dx / r : 1
				let uy = r > 1e-9 ? dy / r : 0
				let target = baseR + depths[i] * spacing
				let mag = (target - r) * strength * alpha
				nodes[i].vx = nodes[i].vx + ux * mag
				nodes[i].vy = nodes[i].vy + uy * mag
			}
		}
	}
}

struct ClusterPullForce: Sendable {
	var nodeCluster: [Int]
	var clusterCount: Int
	var strength: Double
	var orphan: [Bool]?
	var mode: DepthAnchorMode
	var ringCx: Double
	var ringCy: Double

	func apply(_ nodes: inout [LayoutNode], alpha: Double) {
		var sumX = [Double](repeating: 0, count: clusterCount)
		var sumY = [Double](repeating: 0, count: clusterCount)
		var cnt = [Double](repeating: 0, count: clusterCount)
		for i in nodes.indices {
			let ci = nodeCluster[i]
			if ci < 0 { continue }
			sumX[ci] = sumX[ci] + nodes[i].x
			sumY[ci] = sumY[ci] + nodes[i].y
			cnt[ci] = cnt[ci] + 1
		}
		for i in nodes.indices {
			let ci = nodeCluster[i]
			if ci < 0 || cnt[ci] < 2 { continue }
			let px = nodes[i].x
			let py = nodes[i].y
			let ux = sumX[ci] / cnt[ci] - px
			let uy = sumY[ci] / cnt[ci] - py
			if orphan?[i] == true {
				nodes[i].vx = nodes[i].vx + ux * strength * alpha
				nodes[i].vy = nodes[i].vy + uy * strength * alpha
			} else if mode == .vertical {
				nodes[i].vx = nodes[i].vx + ux * strength * alpha
			} else if mode == .radial {
				let rx = px - ringCx
				let ry = py - ringCy
				let r = JSMath.hypot(rx, ry)
				if r > 1e-9 {
					// Tangential component: u − (u·r̂)r̂
					let dot = (ux * rx + uy * ry) / (r * r)
					nodes[i].vx = nodes[i].vx + (ux - dot * rx) * strength * alpha
					nodes[i].vy = nodes[i].vy + (uy - dot * ry) * strength * alpha
				}
			} else {
				nodes[i].vx = nodes[i].vx + ux * strength * alpha
				nodes[i].vy = nodes[i].vy + uy * strength * alpha
			}
		}
	}
}

/// The one force set. Returns a stopped simulation over `nodes` (d3 seeds
/// unplaced nodes on its phyllotaxis spiral). Throws when an edge names a
/// node that is not in `nodes`, as d3's forceLink does.
public func createGraphSimulation(
	nodes inputNodes: [LayoutNode],
	edges: [LayoutEdge],
	options: SimOptions = SimOptions(),
) throws(LayoutError) -> GraphSimulation {
	var nodes = inputNodes
	D3SimulationCore.initializeNodes(&nodes)

	var degree: [String: Double] = [:]
	for e in edges {
		degree[e.from, default: 0] += 1
		degree[e.to, default: 0] += 1
	}
	let linkStrength = options.linkStrength ?? 1
	let linkDistance = options.linkDistance ?? LINK_DISTANCE
	let ids = nodes.map(\.id)

	var sim = GraphSimulation(nodes: nodes)
	let link = try D3LinkForce(
		links: edges,
		nodes: nodes,
		strength: { _, s, t in
			(linkStrength * 1) / Swift.min(degree[ids[s]] ?? 1, degree[ids[t]] ?? 1)
		},
		distance: { _, s, t in
			isImpId(ids[s]) || isImpId(ids[t]) ? linkDistance / 2 : linkDistance
		},
	)
	sim.forces.append(.link(link))
	sim.forces.append(.manyBody(D3ManyBodyForce(nodeCount: nodes.count, strength: options.chargeStrength ?? CHARGE_STRENGTH)))
	sim.alphaDecay = options.alphaDecay ?? 0.0228
	sim.velocityDecay = options.velocityDecay ?? 0.4

	// Depth mode projections, with the ORPHAN RULE: a node with no logical
	// edges has no dependency structure, so it is exempt from the depth
	// force and keeps the regular view's forces.
	let mode = options.depthAnchor?.mode ?? .off
	let depthEdges = options.logicalEdges ?? edges
	var orphan: [Bool]?
	var depthsComputed: [String: Double] = [:]
	if mode != .off {
		var connected = Set<String>()
		let valid = Set(ids)
		for e in depthEdges {
			if e.from == e.to || !valid.contains(e.from) || !valid.contains(e.to) { continue }
			connected.insert(e.from)
			connected.insert(e.to)
		}
		// Proposition ranks first, then the IMP MIDPOINT ANCHOR: an imp
		// node's depth = (highest premise row + conclusion row) / 2.
		for (id, d) in inferenceDepths(nodeIds: ids.filter { !isImpId($0) }, edges: depthEdges) {
			depthsComputed[id] = Double(d)
		}
		var anchored = Set<String>()
		for link in options.impLinks ?? [] {
			guard let conclusionDepth = depthsComputed[link.conclusion], !link.premises.isEmpty else { continue }
			var highest = -Double.infinity
			var complete = true
			for premise in link.premises {
				guard let d = depthsComputed[premise] else {
					complete = false
					break
				}
				if d > highest { highest = d }
			}
			if !complete { continue }
			depthsComputed[link.id] = (highest + conclusionDepth) / 2
			anchored.insert(link.id)
		}
		orphan = ids.map { id in
			!connected.contains(id) && !(isImpId(id) && anchored.contains(id))
		}
	}

	if let g = options.gravity {
		if mode == .off {
			sim.forces.append(.position(D3PositionForce(axis: .x, target: g.x, strength: g.strength)))
			sim.forces.append(.position(D3PositionForce(axis: .y, target: g.y, strength: g.strength)))
		} else {
			sim.forces.append(.projectedGravity(mode: mode, gravity: g, orphan: orphan!))
		}
	}

	if let cp = options.clusterPull, cp.strength > 0, !cp.clusters.isEmpty {
		var clusterIdx: [String: Int] = [:]
		for (i, members) in cp.clusters.enumerated() {
			for id in members { clusterIdx[id] = i }
		}
		sim.forces.append(.clusterPull(ClusterPullForce(
			nodeCluster: ids.map { clusterIdx[$0] ?? -1 },
			clusterCount: cp.clusters.count,
			strength: cp.strength,
			orphan: orphan,
			mode: mode,
			ringCx: options.depthAnchor?.center?.x ?? 0,
			ringCy: options.depthAnchor?.center?.y ?? 0,
		)))
	}

	if let da = options.depthAnchor, da.mode != .off, da.strength > 0 {
		let depths = ids.map { depthsComputed[$0] ?? 0 }
		let c = da.center ?? Position(x: 0, y: 0)
		if da.mode == .vertical {
			sim.forces.append(.depthVertical(depths: depths, orphan: orphan, baseY: c.y, spacing: da.spacing, strength: da.strength))
		} else {
			sim.forces.append(.depthRadial(depths: depths, orphan: orphan, center: c, baseRadius: da.baseRadius ?? 0, spacing: da.spacing, strength: da.strength))
		}
	}
	return sim
}

// MARK: - incrementalLayout

public struct IncrementalLayoutOptions: Sendable, Hashable {
	/// Manual ticks for the settle (default 300).
	public var ticks: Int?
	/// Per-tick anchor re-blend (default 0.85; 1 = fully pinned).
	public var anchorRetention: Double?
	/// Gravity strength override (default: bootstrap/incremental constants).
	public var gravityStrength: Double?
	/// Cluster partition (member id lists); nil = no cluster pull.
	public var clusters: [[String]]?
	/// Cluster pull strength (default CLUSTER_PULL_STRENGTH).
	public var clusterPullStrength: Double?
	/// Depth anchoring; `center` defaults to the anchored core's centroid.
	public var depthAnchor: DepthAnchor?
	public var logicalEdges: [LayoutEdge]?
	public var impLinks: [ImpLink]?

	public init(
		ticks: Int? = nil,
		anchorRetention: Double? = nil,
		gravityStrength: Double? = nil,
		clusters: [[String]]? = nil,
		clusterPullStrength: Double? = nil,
		depthAnchor: DepthAnchor? = nil,
		logicalEdges: [LayoutEdge]? = nil,
		impLinks: [ImpLink]? = nil,
	) {
		self.ticks = ticks
		self.anchorRetention = anchorRetention
		self.gravityStrength = gravityStrength
		self.clusters = clusters
		self.clusterPullStrength = clusterPullStrength
		self.depthAnchor = depthAnchor
		self.logicalEdges = logicalEdges
		self.impLinks = impLinks
	}
}

/// One incremental settle. `nodeIds`/`edges` describe the current graph;
/// `previous` is the positions ledger (empty on the first settle, which then
/// degrades to a seeded-scatter bootstrap). Returns a position for every node.
public func incrementalLayout(
	nodeIds: [String],
	edges: [LayoutEdge],
	previous: [String: Position],
	options: IncrementalLayoutOptions = IncrementalLayoutOptions(),
) throws(LayoutError) -> [String: Position] {
	let ticks = options.ticks ?? 300
	let retention = options.anchorRetention ?? ANCHOR_RETENTION

	// Anchors: the warm-start set, insertion-ordered like the JS Map.
	var anchorOrder: [String] = []
	var anchors: [String: Position] = [:]
	func setAnchor(_ id: String, _ p: Position) {
		if anchors.updateValue(p, forKey: id) == nil { anchorOrder.append(id) }
	}
	for id in nodeIds {
		if let prev = previous[id] { setAnchor(id, Position(x: prev.x, y: prev.y)) }
	}

	var minX = Double.infinity
	var maxX = -Double.infinity
	var minY = Double.infinity
	var maxY = -Double.infinity
	var cx = 0.0
	var cy = 0.0
	for id in anchorOrder {
		let a = anchors[id]!
		minX = jsMin(minX, a.x)
		maxX = jsMax(maxX, a.x)
		minY = jsMin(minY, a.y)
		maxY = jsMax(maxY, a.y)
		cx += a.x
		cy += a.y
	}
	let hasCore = !anchorOrder.isEmpty
	if hasCore {
		cx /= Double(anchorOrder.count)
		cy /= Double(anchorOrder.count)
	}
	let coreRadius = hasCore ? jsMax(maxX - minX, maxY - minY) / 2 : 1

	var adjacency: [String: [String]] = [:]
	func linkTo(_ a: String, _ b: String) {
		if a == b { return }
		adjacency[a, default: []].append(b)
	}
	for e in edges {
		linkTo(e.from, e.to)
		linkTo(e.to, e.from)
	}

	// Rim radius from the connected core's mean radius (orphans never inflate it).
	var rimRadius = 0.0
	var connectedAnchored = 0
	for id in anchorOrder {
		if (adjacency[id]?.count ?? 0) == 0 { continue }
		let a = anchors[id]!
		connectedAnchored += 1
		rimRadius += JSMath.hypot(a.x - cx, a.y - cy)
	}
	if connectedAnchored > 0 {
		rimRadius = (rimRadius / Double(connectedAnchored)) * 1.7
	} else if hasCore {
		rimRadius = coreRadius * 1.15
	}
	rimRadius += 4

	var simNodes: [LayoutNode] = []
	simNodes.reserveCapacity(nodeIds.count)
	for id in nodeIds {
		var rand = LayoutSeededRandom(id)
		var x: Double
		var y: Double
		if let anchor = anchors[id] {
			x = anchor.x
			y = anchor.y
		} else {
			var sx = 0.0
			var sy = 0.0
			var found = 0
			for nbr in adjacency[id] ?? [] {
				if let na = anchors[nbr] {
					sx += na.x
					sy += na.y
					found += 1
				}
			}
			if found > 0 {
				x = sx / Double(found) + (rand.next() - 0.5) * 8
				y = sy / Double(found) + (rand.next() - 0.5) * 8
			} else if hasCore {
				let angle = rand.next() * Double.pi * 2
				let radius = rimRadius + rand.next() * 8
				x = cx + JSMath.cos(angle) * radius
				y = cy + JSMath.sin(angle) * radius
				// An orphan's intended rest spot IS the rim seed.
				setAnchor(id, Position(x: x, y: y))
			} else {
				x = (rand.next() - 0.5) * 100
				y = (rand.next() - 0.5) * 100
			}
		}
		if x == 0 && y == 0 { x = 0.5 }
		simNodes.append(LayoutNode(id: id, x: x, y: y))
	}

	let depthAnchor: DepthAnchor? = options.depthAnchor.map { da in
		guard da.mode != .off else { return da }
		var d = da
		d.center = da.center ?? Position(x: cx, y: cy)
		return d
	}
	var sim = try createGraphSimulation(
		nodes: simNodes,
		edges: edges,
		options: SimOptions(
			gravity: LayoutGravity(x: cx, y: cy, strength: options.gravityStrength ?? (hasCore ? INCREMENTAL_GRAVITY : BOOTSTRAP_GRAVITY)),
			depthAnchor: depthAnchor,
			logicalEdges: options.logicalEdges,
			impLinks: options.impLinks,
			clusterPull: options.clusters.map { ClusterPull(clusters: $0, strength: options.clusterPullStrength ?? CLUSTER_PULL_STRENGTH) },
		),
	)
	let dMode = options.depthAnchor?.mode ?? .off
	let dCenter = options.depthAnchor?.center ?? Position(x: cx, y: cy)
	var byId: [String: Int] = [:]
	for (i, n) in simNodes.enumerated() { byId[n.id] = i }
	let blended = anchorOrder.compactMap { id -> (Int, Position)? in
		guard let i = byId[id] else { return nil }
		return (i, anchors[id]!)
	}
	for _ in 0..<ticks {
		sim.tick()
		// Anchor re-blend (position space). Depth modes blend the free
		// dimension only: x in vertical mode, the angle in radial mode.
		guard hasCore && retention < 1 else { continue }
		for (i, a) in blended {
			if sim.nodes[i].fx != nil || sim.nodes[i].fy != nil { continue }
			let x = sim.nodes[i].x
			let y = sim.nodes[i].y
			switch dMode {
			case .vertical:
				sim.nodes[i].x = a.x + (x - a.x) * retention
			case .radial:
				let rx = x - dCenter.x
				let ry = y - dCenter.y
				let r = JSMath.hypot(rx, ry)
				let ax = a.x - dCenter.x
				let ay = a.y - dCenter.y
				let ar = JSMath.hypot(ax, ay)
				if r > 1e-9 && ar > 1e-9 {
					let theta = JSMath.atan2(ry, rx)
					let thetaA = JSMath.atan2(ay, ax)
					let blend = thetaA + JSMath.atan2(JSMath.sin(theta - thetaA), JSMath.cos(theta - thetaA)) * retention
					sim.nodes[i].x = dCenter.x + r * JSMath.cos(blend)
					sim.nodes[i].y = dCenter.y + r * JSMath.sin(blend)
				}
			case .off:
				sim.nodes[i].x = a.x + (x - a.x) * retention
				sim.nodes[i].y = a.y + (y - a.y) * retention
			}
		}
	}

	var out: [String: Position] = [:]
	for n in sim.nodes { out[n.id] = Position(x: n.x, y: n.y) }
	return out
}

public func incrementalLayout(
	_ nodes: [GraphNode],
	edges: [LayoutEdge],
	previous: [String: Position],
	options: IncrementalLayoutOptions = IncrementalLayoutOptions(),
) throws(LayoutError) -> [String: Position] {
	try incrementalLayout(nodeIds: nodes.map(\.id), edges: edges, previous: previous, options: options)
}

// MARK: - JS helpers

/// `Math.min` for two numbers (NaN-propagating).
@inline(__always) private func jsMin(_ a: Double, _ b: Double) -> Double {
	a.isNaN || b.isNaN ? .nan : Swift.min(a, b)
}

/// `Math.max` for two numbers (NaN-propagating).
@inline(__always) private func jsMax(_ a: Double, _ b: Double) -> Double {
	a.isNaN || b.isNaN ? .nan : Swift.max(a, b)
}

/// A private copy of question-core's `seededRandom`: mulberry32 seeded by a
/// FNV-1a hash of the string's UTF-16 units.
struct LayoutSeededRandom: Sendable {
	private var a: UInt32

	init(_ seed: String) {
		var h: UInt32 = 2_166_136_261
		for unit in seed.utf16 {
			h ^= UInt32(unit)
			h = h &* 16_777_619
		}
		a = h
	}

	mutating func next() -> Double {
		a = a &+ 0x6D2B_79F5
		var t = (a ^ (a >> 15)) &* (1 | a)
		t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
		return Double(t ^ (t >> 14)) / 4_294_967_296
	}
}
