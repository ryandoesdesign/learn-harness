import Foundation

// Port of the d3-force 3.0.0 subset that core/layout.ts uses: the simulation
// tick loop, lcg + jiggle, forceLink, forceManyBody (Barnes-Hut over
// d3-quadtree) and forceX/forceY. Each step follows the JS operation for
// operation, so the results match d3's floating point exactly.

/// d3's random source (lcg.js): a 32-bit LCG seeded at 1.
public struct D3LCG: Sendable, Hashable {
	private var s: UInt64 = 1
	public init() {}
	public mutating func next() -> Double {
		s = (1_664_525 &* s &+ 1_013_904_223) % 4_294_967_296
		return Double(s) / 4_294_967_296
	}
}

/// d3's jiggle: a tiny random offset that breaks exact coincidence.
@inline(__always) func d3Jiggle(_ random: inout D3LCG) -> Double {
	(random.next() - 0.5) * 1e-6
}

/// A node the simulation mutates: position, velocity, and an optional pin
/// per axis (d3's fx/fy).
public struct LayoutNode: Sendable, Hashable {
	public var id: String
	/// NaN on either axis means "unplaced": the simulation seeds it on d3's
	/// phyllotaxis spiral.
	public var position: SIMD2<Double>
	public var velocity: SIMD2<Double>
	public var fx: Double?
	public var fy: Double?

	public init(id: String, x: Double = .nan, y: Double = .nan, vx: Double = .nan, vy: Double = .nan, fx: Double? = nil, fy: Double? = nil) {
		self.id = id
		self.position = SIMD2(x, y)
		self.velocity = SIMD2(vx, vy)
		self.fx = fx
		self.fy = fy
	}

	public var x: Double {
		get { position.x }
		set { position.x = newValue }
	}
	public var y: Double {
		get { position.y }
		set { position.y = newValue }
	}
	public var vx: Double {
		get { velocity.x }
		set { velocity.x = newValue }
	}
	public var vy: Double {
		get { velocity.y }
		set { velocity.y = newValue }
	}
}

public enum LayoutError: Error, Sendable, Hashable {
	/// A link endpoint names no node (d3: "node not found: <id>").
	case nodeNotFound(String)
}

// MARK: - forceLink

struct D3LinkForce: Sendable {
	var sources: [Int]
	var targets: [Int]
	var strengths: [Double]
	var distances: [Double]
	var bias: [Double]
	var iterations = 1

	/// `initialize`: resolve ids, count degrees, then the bias, strength and
	/// distance per link. `strength`/`distance` get the link's index plus
	/// its resolved endpoints.
	init(
		links: [GraphEdge],
		nodes: [LayoutNode],
		strength: ((Int, Int, Int) -> Double)?,
		distance: (Int, Int, Int) -> Double,
	) throws(LayoutError) {
		var nodeById: [String: Int] = [:]
		for (i, n) in nodes.enumerated() { nodeById[n.id] = i }
		let m = links.count
		var srcs: [Int] = []
		var tgts: [Int] = []
		srcs.reserveCapacity(m)
		tgts.reserveCapacity(m)
		var count = [Double](repeating: 0, count: nodes.count)
		for link in links {
			guard let s = nodeById[link.from] else { throw .nodeNotFound(link.from) }
			guard let t = nodeById[link.to] else { throw .nodeNotFound(link.to) }
			srcs.append(s)
			tgts.append(t)
			count[s] += 1
			count[t] += 1
		}
		sources = srcs
		targets = tgts
		bias = (0..<m).map { count[srcs[$0]] / (count[srcs[$0]] + count[tgts[$0]]) }
		strengths = (0..<m).map { i in
			strength?(i, srcs[i], tgts[i]) ?? 1 / Swift.min(count[srcs[i]], count[tgts[i]])
		}
		distances = (0..<m).map { distance($0, srcs[$0], tgts[$0]) }
	}

	func apply(_ nodes: inout [LayoutNode], alpha: Double, random: inout D3LCG) {
		let n = sources.count
		for _ in 0..<iterations {
			for i in 0..<n {
				let si = sources[i]
				let ti = targets[i]
				var x = nodes[ti].x + nodes[ti].vx - nodes[si].x - nodes[si].vx
				if x == 0 || x.isNaN { x = d3Jiggle(&random) }
				var y = nodes[ti].y + nodes[ti].vy - nodes[si].y - nodes[si].vy
				if y == 0 || y.isNaN { y = d3Jiggle(&random) }
				var l = (x * x + y * y).squareRoot()
				l = (l - distances[i]) / l * alpha * strengths[i]
				x *= l
				y *= l
				var b = bias[i]
				nodes[ti].vx -= x * b
				nodes[ti].vy -= y * b
				b = 1 - b
				nodes[si].vx += x * b
				nodes[si].vy += y * b
			}
		}
	}
}

// MARK: - forceManyBody

struct D3ManyBodyForce: Sendable {
	var strengths: [Double]
	var distanceMin2 = 1.0
	var distanceMax2 = Double.infinity
	var theta2 = 0.81

	init(nodeCount: Int, strength: Double) {
		strengths = [Double](repeating: strength, count: nodeCount)
	}

	func apply(_ nodes: inout [LayoutNode], alpha: Double, random: inout D3LCG) {
		let n = nodes.count
		var tree = D3Quadtree(xs: nodes.map(\.x), ys: nodes.map(\.y))
		let strengths = self.strengths
		// accumulate
		tree.visitAfter { tree, q in
			var strength = 0.0
			if tree[q].isInternal {
				var weight = 0.0
				var x = 0.0
				var y = 0.0
				for i in 0..<4 {
					let child = tree[q][i]
					guard child >= 0 else { continue }
					let cq = tree[child]
					let c = Swift.abs(cq.value)
					if c != 0 && !c.isNaN {
						strength += cq.value
						weight += c
						x += c * cq.x
						y += c * cq.y
					}
				}
				tree[q].x = x / weight
				tree[q].y = y / weight
			} else {
				tree[q].x = tree.pointX(tree[q].data)
				tree[q].y = tree.pointY(tree[q].data)
				var p = q
				repeat {
					strength += strengths[tree[p].data]
					p = tree[p].next
				} while p >= 0
			}
			tree[q].value = strength
		}
		let distanceMin2 = self.distanceMin2
		let distanceMax2 = self.distanceMax2
		let theta2 = self.theta2
		for node in 0..<n {
			let nodeX = nodes[node].x
			let nodeY = nodes[node].y
			var vx = nodes[node].vx
			var vy = nodes[node].vy
			tree.visit { q, x1, _, x2, _ in
				let quad = tree[q]
				if quad.value == 0 || quad.value.isNaN { return true }
				var x = quad.x - nodeX
				var y = quad.y - nodeY
				var w = x2 - x1
				var l = x * x + y * y
				if w * w / theta2 < l {
					if l < distanceMax2 {
						if x == 0 { x = d3Jiggle(&random); l += x * x }
						if y == 0 { y = d3Jiggle(&random); l += y * y }
						if l < distanceMin2 { l = (distanceMin2 * l).squareRoot() }
						vx += x * quad.value * alpha / l
						vy += y * quad.value * alpha / l
					}
					return true
				} else if quad.isInternal || l >= distanceMax2 {
					return false
				}
				if quad.data != node || quad.next >= 0 {
					if x == 0 { x = d3Jiggle(&random); l += x * x }
					if y == 0 { y = d3Jiggle(&random); l += y * y }
					if l < distanceMin2 { l = (distanceMin2 * l).squareRoot() }
				}
				var p = q
				repeat {
					let leaf = tree[p]
					if leaf.data != node {
						w = strengths[leaf.data] * alpha / l
						vx += x * w
						vy += y * w
					}
					p = leaf.next
				} while p >= 0
				return false
			}
			nodes[node].vx = vx
			nodes[node].vy = vy
		}
	}
}

// MARK: - forceX / forceY

/// forceX or forceY with constant target and strength.
struct D3PositionForce: Sendable {
	enum Axis: Sendable { case x, y }
	var axis: Axis
	var target: Double
	var strength: Double

	func apply(_ nodes: inout [LayoutNode], alpha: Double) {
		// d3 zeroes the strength of a NaN target.
		let s = target.isNaN ? 0 : strength
		switch axis {
		case .x:
			for i in nodes.indices { nodes[i].vx += (target - nodes[i].x) * s * alpha }
		case .y:
			for i in nodes.indices { nodes[i].vy += (target - nodes[i].y) * s * alpha }
		}
	}
}

// MARK: - Simulation core

/// d3's forceSimulation state minus the timer (callers tick manually).
struct D3SimulationCore: Sendable {
	var alpha = 1.0
	var alphaMin = 0.001
	/// d3's default, 1 − alphaMin^(1/300), as V8 computes it.
	var alphaDecay = 0.02276277904418933
	var alphaTarget = 0.0
	/// Stored as d3 stores it: 1 − the configured decay.
	var velocityDecayFactor = 0.6
	var random = D3LCG()

	private static let initialRadius = 10.0
	private static let initialAngle = Double.pi * (3 - 5.0.squareRoot())

	/// initializeNodes: apply pins, phyllotaxis-seed unplaced nodes, zero
	/// missing velocities.
	static func initializeNodes(_ nodes: inout [LayoutNode]) {
		for i in nodes.indices {
			if let fx = nodes[i].fx { nodes[i].x = fx }
			if let fy = nodes[i].fy { nodes[i].y = fy }
			if nodes[i].x.isNaN || nodes[i].y.isNaN {
				let radius = initialRadius * (0.5 + Double(i)).squareRoot()
				let angle = Double(i) * initialAngle
				nodes[i].x = radius * JSMath.cos(angle)
				nodes[i].y = radius * JSMath.sin(angle)
			}
			if nodes[i].vx.isNaN || nodes[i].vy.isNaN {
				nodes[i].vx = 0
				nodes[i].vy = 0
			}
		}
	}

	/// Advance alpha one step; returns the new alpha for the forces.
	mutating func stepAlpha() -> Double {
		alpha += (alphaTarget - alpha) * alphaDecay
		return alpha
	}

	/// The integration half of a tick.
	func integrate(_ nodes: inout [LayoutNode]) {
		let decay = velocityDecayFactor
		for i in nodes.indices {
			if let fx = nodes[i].fx {
				nodes[i].x = fx
				nodes[i].vx = 0
			} else {
				nodes[i].vx *= decay
				nodes[i].x += nodes[i].vx
			}
			if let fy = nodes[i].fy {
				nodes[i].y = fy
				nodes[i].vy = 0
			} else {
				nodes[i].vy *= decay
				nodes[i].y += nodes[i].vy
			}
		}
	}
}
