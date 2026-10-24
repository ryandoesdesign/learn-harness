import Foundation
import Testing
@testable import LHCore

// Port of tests/layout.test.ts (the settleGraphLayout cases belong to
// layout-settle, which is ported later), plus golden parity against the TS
// layout over the golden graph (scripts/core-golden/layout.ts).

private func edge(_ from: String, _ to: String) -> LayoutEdge { LayoutEdge(from: from, to: to) }
private func mk(_ id: String, _ x: Double, _ y: Double) -> LayoutNode { LayoutNode(id: id, x: x, y: y) }

private func mean(_ positions: [String: Position], _ ids: [String]) -> (x: Double, y: Double) {
	(
		ids.reduce(0) { $0 + positions[$1]!.x } / Double(ids.count),
		ids.reduce(0) { $0 + positions[$1]!.y } / Double(ids.count)
	)
}

private func xSpan(_ positions: [String: Position]) -> Double {
	let xs = positions.values.map(\.x)
	return xs.max()! - xs.min()!
}

private func byId(_ sim: GraphSimulation) -> [String: LayoutNode] {
	Dictionary(sim.nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
}

private func ticked(_ sim: GraphSimulation, _ n: Int) -> GraphSimulation {
	var sim = sim
	sim.tick(n)
	return sim
}

@Suite struct IncrementalLayoutTests {
	@Test func bootstrapsDeterministicallyFromAnEmptyLedger() throws {
		let nodes = ["a", "b", "c", "d"]
		let edges = [edge("a", "b"), edge("b", "c"), edge("c", "d")]
		let first = try incrementalLayout(nodeIds: nodes, edges: edges, previous: [:])
		let second = try incrementalLayout(nodeIds: nodes, edges: edges, previous: [:])
		#expect(first.count == 4)
		for (id, p) in first {
			#expect(p.x.isFinite && p.y.isFinite, "finite coords for \(id)")
			#expect(p == second[id], "deterministic position for \(id)")
		}
	}

	@Test func restStateIsStable() throws {
		let nodes = ["a", "b", "c", "d", "e"]
		let edges = [edge("a", "b"), edge("b", "c"), edge("c", "d"), edge("d", "e"), edge("a", "e")]
		let rest = try incrementalLayout(nodeIds: nodes, edges: edges, previous: [:])
		let span = xSpan(rest)
		let again = try incrementalLayout(nodeIds: nodes, edges: edges, previous: rest)
		var maxShift = 0.0
		for (id, p) in rest {
			let q = again[id]!
			maxShift = max(maxShift, JSMath.hypot(p.x - q.x, p.y - q.y))
		}
		#expect(maxShift < span * 0.1, "re-settle drift \(maxShift) should be < 10% of span \(span)")
	}

	@Test func evolvesAnchoredNodeStaysNearItsAnchor() throws {
		let core = ["a", "b", "c"]
		let coreEdges = [edge("a", "b"), edge("b", "c")]
		let previous = try incrementalLayout(nodeIds: core, edges: coreEdges, previous: [:])
		let anchor = previous["b"]!
		let next = try incrementalLayout(
			nodeIds: core + ["d", "e"],
			edges: coreEdges + [edge("b", "d"), edge("d", "e")],
			previous: previous,
		)
		let coreSpanBefore = xSpan(previous)
		#expect(JSMath.hypot(next["b"]!.x - anchor.x, next["b"]!.y - anchor.y) < coreSpanBefore, "anchored node b stays near its previous position")
		let centroid = mean(next, ["b", "d", "e"])
		#expect(JSMath.hypot(next["d"]!.x - centroid.x, next["d"]!.y - centroid.y) < coreSpanBefore * 2, "new neighbor d landed near the cluster it arrived with")
	}

	@Test func rimOrphanEndsUpOutsideTheAnchoredCore() throws {
		let core = ["a", "b", "c", "d", "e"]
		let coreEdges = [edge("a", "b"), edge("b", "c"), edge("c", "d"), edge("d", "e"), edge("a", "e"), edge("b", "d")]
		let previous = try incrementalLayout(nodeIds: core, edges: coreEdges, previous: [:])
		let next = try incrementalLayout(nodeIds: core + ["orphan"], edges: coreEdges, previous: previous)
		let c = mean(previous, core)
		let coreMax = next.filter { $0.key != "orphan" }.map { JSMath.hypot($0.value.x - c.x, $0.value.y - c.y) }.max()!
		let orphanR = JSMath.hypot(next["orphan"]!.x - c.x, next["orphan"]!.y - c.y)
		#expect(orphanR > coreMax, "orphan at r=\(orphanR) should sit outside core max r=\(coreMax)")
	}

	@Test func unknownEdgeEndpointThrowsLikeD3() {
		#expect(throws: LayoutError.nodeNotFound("ghost")) {
			try incrementalLayout(nodeIds: ["a"], edges: [edge("a", "ghost")], previous: [:])
		}
	}
}

@Suite struct ImpLinkHalfDistanceTests {
	private func settle(_ from: String, _ to: String, _ linkDistance: Double) throws -> Double {
		var sim = try createGraphSimulation(
			nodes: [mk(from, 0, 0), mk(to, 500, 0)],
			edges: [edge(from, to)],
			options: SimOptions(linkDistance: linkDistance, chargeStrength: 0, gravity: LayoutGravity(x: 0, y: 0, strength: 0)),
		)
		sim.tick(300)
		#expect(sim.nodes.count == 2, "both nodes present")
		return abs(sim.nodes[1].x - sim.nodes[0].x)
	}

	@Test func plainPropositionLinkSettlesAtTheFullRestLength() throws {
		#expect(abs(try settle("a", "b", 100) - 100) < 2, "plain link ≈ 100")
	}

	@Test func linkTouchingAnImplicationNodeGetsHalfTheRestLength() throws {
		#expect(abs(try settle("a", "arg_x", 100) - 50) < 2, "into-imp link ≈ 50")
		#expect(abs(try settle("arg_x", "b", 100) - 50) < 2, "out-of-imp link ≈ 50")
	}
}

@Suite struct ClusterPullTests {
	@Test func compactsEachClusterTowardItsOwnCentroid() throws {
		func chain(_ p: String, _ baseX: Double) -> [LayoutNode] {
			(0..<8).map { i in mk("\(p)\(i)", baseX + Double(i) * 40, Double(i) * 15) }
		}
		let a = chain("a", -400)
		let b = chain("b", 400)
		let nodes = a + b
		let edges = (0..<7).map { edge(a[$0].id, a[$0 + 1].id) } + (0..<7).map { edge(b[$0].id, b[$0 + 1].id) }
		let clusters = [a.map(\.id), b.map(\.id)]

		func spread(_ ns: [LayoutNode]) -> Double {
			var sum = 0.0
			for group in [ns.filter { $0.id.hasPrefix("a") }, ns.filter { $0.id.hasPrefix("b") }] {
				let cx = group.reduce(0) { $0 + $1.x } / Double(group.count)
				let cy = group.reduce(0) { $0 + $1.y } / Double(group.count)
				sum += group.reduce(0) { $0 + JSMath.hypot($1.x - cx, $1.y - cy) } / Double(group.count)
			}
			return sum
		}
		func run(_ strength: Double) throws -> Double {
			var sim = try createGraphSimulation(nodes: nodes, edges: edges, options: SimOptions(clusterPull: ClusterPull(clusters: clusters, strength: strength)))
			sim.tick(150)
			return spread(sim.nodes)
		}
		let pulled = try run(0.15)
		let unpulled = try run(0)
		#expect(pulled < unpulled * 0.8, "pulled spread \(pulled) should be well under \(unpulled)")
		#expect(pulled > 0, "spread is finite/positive")
	}
}

@Suite struct LogicalDepthTests {
	@Test func multiPremiseConclusionSitsOneAboveItsPremises() {
		let depths = inferenceDepths(nodeIds: ["a", "b", "c"], edges: [edge("a", "c"), edge("b", "c")])
		#expect(depths["c"] == 1, "one inference hop from BOTH premises")
	}

	@Test func impNodeIsAbsentFromTheRankMap() {
		let ids = ["a", "b", "c", "arg_x"].filter { !$0.hasPrefix("arg_") }
		let depths = inferenceDepths(nodeIds: ids, edges: [edge("a", "c"), edge("b", "c")])
		#expect(depths["arg_x"] == nil, "geometry points carry no inference rank")
		#expect(depths["c"] == 1)
	}

	@Test func verticalPoleIsHorizontalOnlyForEveryone() throws {
		let sim = ticked(try createGraphSimulation(
			nodes: [mk("a", 0, 0), mk("b", 40, 0), mk("lonely", 500, 400)],
			edges: [edge("a", "b")],
			options: SimOptions(
				chargeStrength: 0,
				gravity: LayoutGravity(x: 0, y: 0, strength: 0.1),
				depthAnchor: DepthAnchor(mode: .vertical, strength: 1, spacing: 60),
			),
		), 400)
		let pos = byId(sim)
		#expect(abs(pos["lonely"]!.x) < 50, "lonely x pulled to center (got \(pos["lonely"]!.x))")
		#expect(abs(pos["lonely"]!.y - 400) < 5, "lonely y free (got \(pos["lonely"]!.y))")
	}

	private func impFan(_ nodes: [LayoutNode], logical: [LayoutEdge], impLinks: [ImpLink]?, spacing: Double) throws -> [String: LayoutNode] {
		byId(ticked(try createGraphSimulation(
			nodes: nodes,
			edges: [edge("a", "arg_x"), edge("b", "arg_x"), edge("arg_x", "c")],
			options: SimOptions(
				linkStrength: 0.05,
				chargeStrength: 0,
				gravity: LayoutGravity(x: 0, y: 0, strength: 0.1),
				depthAnchor: DepthAnchor(mode: .vertical, strength: 1, spacing: spacing),
				logicalEdges: logical,
				impLinks: impLinks,
			),
		), 400))
	}

	@Test func impMidpointAnchorPinsHalfwayBetweenPremisesAndConclusion() throws {
		let pos = try impFan(
			[mk("a", 0, 0), mk("b", 40, 0), mk("c", 0, -480), mk("arg_x", 20, -100)],
			logical: [edge("a", "c"), edge("b", "c")],
			impLinks: [ImpLink(id: "arg_x", premises: ["a", "b"], conclusion: "c")],
			spacing: 500,
		)
		#expect(abs(pos["a"]!.y) < 50, "a on row 0 (got \(pos["a"]!.y))")
		#expect(abs(pos["b"]!.y) < 50, "b on row 0 (got \(pos["b"]!.y))")
		#expect(abs(pos["c"]!.y + 500) < 50, "c on row 1 (got \(pos["c"]!.y))")
		#expect(abs(pos["arg_x"]!.y + 250) < 40, "arg_x on the half-row (got \(pos["arg_x"]!.y))")
	}

	@Test func mixedDepthPremisesUseTheHighestPremiseRow() throws {
		let pos = try impFan(
			[mk("a", 0, 0), mk("b", 10, 0), mk("c", 0, 0), mk("arg_x", 5, 0)],
			logical: [edge("a", "b"), edge("a", "c"), edge("b", "c")],
			impLinks: [ImpLink(id: "arg_x", premises: ["a", "b"], conclusion: "c")],
			spacing: 400,
		)
		#expect(abs(pos["a"]!.y) < 40, "a on row 0 (got \(pos["a"]!.y))")
		#expect(abs(pos["b"]!.y + 400) < 40, "b on row 1 (got \(pos["b"]!.y))")
		#expect(abs(pos["c"]!.y + 800) < 40, "c on row 2 (got \(pos["c"]!.y))")
		#expect(abs(pos["arg_x"]!.y + 600) < 40, "arg_x on the 1.5 half-row (got \(pos["arg_x"]!.y))")
	}

	@Test func withoutImpLinksTheImpNodeKeepsTheLegacyExemption() throws {
		let pos = try impFan(
			[mk("a", 0, 0), mk("b", 40, 0), mk("c", 0, -480), mk("arg_x", 20, -100)],
			logical: [edge("a", "c"), edge("b", "c")],
			impLinks: nil,
			spacing: 500,
		)
		#expect(abs(pos["c"]!.y + 500) < 50, "c on row 1")
		#expect(abs(pos["arg_x"]!.y) < 250, "arg_x unanchored (got \(pos["arg_x"]!.y))")
	}
}

@Suite struct InferenceDepthsTests {
	@Test func ranksChainDiamondTakesLongestPathOrphansAreZero() {
		let d = inferenceDepths(
			nodeIds: ["a", "b", "c", "d", "loner"],
			edges: [edge("a", "b"), edge("b", "c"), edge("a", "d"), edge("b", "d"), edge("c", "d")],
		)
		#expect(d["a"] == 0)
		#expect(d["b"] == 1)
		#expect(d["c"] == 2)
		#expect(d["d"] == 3)
		#expect(d["loner"] == 0)
	}

	@Test func cyclesShareADepth() {
		let ids = ["s", "x", "y", "z"]
		let edges = [edge("s", "x"), edge("x", "y"), edge("y", "x"), edge("x", "z")]
		let d = inferenceDepths(nodeIds: ids, edges: edges)
		#expect(d["s"] == 0)
		#expect(d["x"] == d["y"], "cycle members share a depth")
		#expect(d["x"] == 1)
		#expect(d["z"] == 2)
		#expect(inferenceDepths(nodeIds: ids, edges: edges) == d)
	}
}

@Suite struct DepthAnchorForceTests {
	private func zeros(_ ids: [String]) -> [LayoutNode] { ids.map { mk($0, 0, 0) } }

	@Test func verticalPremiseLandsBelowItsConclusion() throws {
		let pos = byId(ticked(try createGraphSimulation(
			nodes: zeros(["base", "derived"]),
			edges: [edge("base", "derived")],
			options: SimOptions(depthAnchor: DepthAnchor(mode: .vertical, strength: 1.2, spacing: 100, center: Position(x: 0, y: 0))),
		), 300))
		let baseY = pos["base"]!.y
		let derivedY = pos["derived"]!.y
		#expect(baseY > derivedY, "base (\(baseY)) should sit BELOW derived (\(derivedY))")
		#expect(baseY - derivedY > 60, "level separation should be substantial (got \(baseY - derivedY))")
	}

	@Test func radialInferenceDepthBecomesRadius() throws {
		let pos = byId(ticked(try createGraphSimulation(
			nodes: zeros(["base", "mid", "top"]),
			edges: [edge("base", "mid"), edge("mid", "top")],
			options: SimOptions(depthAnchor: DepthAnchor(mode: .radial, strength: 1.2, spacing: 80, center: Position(x: 0, y: 0), baseRadius: 100)),
		), 300))
		let r = { (id: String) in JSMath.hypot(pos[id]!.x, pos[id]!.y) }
		#expect(r("base") < r("mid"), "base ring (\(r("base"))) inside mid (\(r("mid")))")
		#expect(r("mid") < r("top"), "mid ring (\(r("mid"))) inside top (\(r("top")))")
	}

	@Test func settleWithDepthAnchorKeepsXMemoryButSnapsToTheLevel() throws {
		let next = try incrementalLayout(
			nodeIds: ["old", "peer", "child"],
			edges: [edge("old", "child"), edge("peer", "child")],
			previous: ["old": Position(x: 250, y: 300), "peer": Position(x: 260, y: 290)],
			options: IncrementalLayoutOptions(depthAnchor: DepthAnchor(mode: .vertical, strength: 0.6, spacing: 80)),
		)
		let old = next["old"]!
		#expect(abs(old.y - 295) < 20, "old node snaps to the baseline (y=\(old.y))")
		#expect(old.x > 150, "x memory preserved (x=\(old.x))")
		let child = next["child"]!
		#expect(child.y < old.y - 40, "child rises above its premises (child=\(child.y), old=\(old.y))")
	}

	@Test func verticalOrphansAreExemptFromDepthAnchoring() throws {
		let pos = byId(ticked(try createGraphSimulation(
			nodes: [mk("base", 0, 0), mk("derived", 10, 0), mk("loner", 400, -80)],
			edges: [edge("base", "derived")],
			options: SimOptions(
				chargeStrength: 0,
				gravity: LayoutGravity(x: 0, y: 500, strength: 0.1),
				depthAnchor: DepthAnchor(mode: .vertical, strength: 1.5, spacing: 120, center: Position(x: 0, y: 0)),
			),
		), 400))
		#expect(abs(pos["base"]!.y) < 40, "structured base sits on the baseline")
		#expect(pos["derived"]!.y < -60, "derived rises a level")
		let loner = pos["loner"]!
		#expect(abs(loner.y - -80) < 5, "the orphan's y is untouched (y=\(loner.y))")
		#expect(abs(loner.x) < 60, "the orphan still converges on the pole horizontally (x=\(loner.x))")
	}

	@Test func radialOrphansGatherAtTheCenterNotOnTheBaseRing() throws {
		let pos = byId(ticked(try createGraphSimulation(
			nodes: [mk("base", 0, 0), mk("mid", 10, 0), mk("loner", 300, 300)],
			edges: [edge("base", "mid")],
			options: SimOptions(
				gravity: LayoutGravity(x: 0, y: 0, strength: 0.1),
				depthAnchor: DepthAnchor(mode: .radial, strength: 1.5, spacing: 80, center: Position(x: 0, y: 0), baseRadius: 150),
			),
		), 400))
		let r = { (id: String) in JSMath.hypot(pos[id]!.x, pos[id]!.y) }
		#expect(abs(r("base") - 150) < 40, "base sits on the base ring (r=\(r("base")))")
		#expect(r("loner") < 60, "the orphan follows gravity to the center, not the ring (r=\(r("loner")))")
	}
}

// MARK: - d3 primitives

@Suite struct D3PrimitiveTests {
	@Test func lcgMatchesD3() {
		// d3-force lcg(): s = (1664525·s + 1013904223) mod 2^32, from s = 1.
		var r = D3LCG()
		#expect(r.next() == 1_015_568_748.0 / 4_294_967_296)
		#expect(r.next() == 1_586_005_467.0 / 4_294_967_296)
	}

	@Test func seededRandomMatchesQuestionCore() {
		// seededRandom("a") from src/core/question-core.ts, first three draws.
		var r = LayoutSeededRandom("a")
		#expect([r.next(), r.next(), r.next()] == [0.621685681398958, 0.30822347407229245, 0.36686075991019607])
	}

	@Test func unplacedNodesStartOnThePhyllotaxisSpiral() throws {
		let sim = try createGraphSimulation(nodes: [LayoutNode(id: "a"), LayoutNode(id: "b")], edges: [])
		// d3: radius = 10·√(0.5 + i), angle = i·π(3 − √5).
		#expect(sim.nodes[0].x == 10 * 0.5.squareRoot())
		#expect(sim.nodes[0].y == 0)
		#expect(sim.nodes[1].x == -9.03088751750192)
		#expect(sim.nodes[1].y == 8.273032735715967)
	}
}

// MARK: - Golden parity

/// Positions must match the TS within this relative tolerance. The port is
/// bit-exact on arm64 today (V8's Math functions are reproduced exactly; see
/// LayoutJSMath.swift), so the observed drift is 0.
private let PARITY_TOLERANCE = 1e-6

private struct GoldenLayoutInput {
	var nodeIds: [String]
	var edges: [LayoutEdge]
	var logicalEdges: [LayoutEdge]
	var impLinks: [ImpLink]
	var clusters: [[String]]
	var previous: [String: Position]
	var previousSubset: [String: Position]

	init() throws {
		let raw = try Golden.load("layout.input")
		func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }
		func edges(_ v: JSONValue?) -> [LayoutEdge] {
			(v?.arrayValue ?? []).map { LayoutEdge(from: $0["from"]!.stringValue!, to: $0["to"]!.stringValue!) }
		}
		func positions(_ v: JSONValue?) -> [String: Position] {
			var out: [String: Position] = [:]
			for (k, p) in v?.objectValue ?? JSONObject() { out[k] = Position(x: p["x"]!.doubleValue!, y: p["y"]!.doubleValue!) }
			return out
		}
		nodeIds = strings(raw["nodeIds"])
		self.edges = edges(raw["edges"])
		logicalEdges = edges(raw["logicalEdges"])
		impLinks = (raw["impLinks"]?.arrayValue ?? []).map {
			ImpLink(id: $0["id"]!.stringValue!, premises: strings($0["premises"]), conclusion: $0["conclusion"]!.stringValue!)
		}
		clusters = (raw["clusters"]?.arrayValue ?? []).map { strings($0) }
		previous = positions(raw["previous"])
		previousSubset = positions(raw["previousSubset"])
	}
}

/// Max relative drift between two position lists (JSON rows with x/y…).
private func maxDrift(_ a: JSONValue, _ b: JSONValue) -> Double {
	var worst = 0.0
	for (ra, rb) in zip(a.arrayValue ?? [], b.arrayValue ?? []) {
		for key in ["x", "y", "vx", "vy"] {
			guard let x = ra[key]?.doubleValue, let y = rb[key]?.doubleValue else { continue }
			worst = max(worst, abs(x - y) / max(1, abs(x), abs(y)))
		}
	}
	return worst
}

@Suite struct LayoutGoldenTests {
	@Test func inferenceDepthsMatchTS() throws {
		let input = try GoldenLayoutInput()
		let golden = try Golden.load("layout.depths")
		let depths = inferenceDepths(nodeIds: input.nodeIds.filter { !$0.hasPrefix("arg_") }, edges: input.logicalEdges)
		let actual = JSONValue.object(JSONObject(pairs: depths.map { ($0.key, JSONValue.number($0.value)) }))
		expectJSONEqual(actual, golden)
	}

	@Test(arguments: ["off", "live", "vertical", "radial"])
	func simulationMatchesTS(name: String) throws {
		let input = try GoldenLayoutInput()
		let golden = try #require(try Golden.load("layout.simulation")[name])
		let pull = ClusterPull(clusters: input.clusters, strength: 0.15)
		let options: SimOptions
		var seeded = true
		switch name {
		case "off":
			seeded = false
			options = SimOptions(gravity: LayoutGravity(x: 0, y: 0, strength: 0.12), clusterPull: pull)
		case "live":
			options = SimOptions(
				linkDistance: 55,
				linkStrength: 0.7,
				chargeStrength: -180,
				gravity: LayoutGravity(x: 10, y: -20, strength: 0.12),
				alphaDecay: 0.05,
				velocityDecay: 0.3,
				clusterPull: pull,
			)
		case "vertical":
			options = SimOptions(
				gravity: LayoutGravity(x: 0, y: 0, strength: 0.12),
				depthAnchor: DepthAnchor(mode: .vertical, strength: 0.3, spacing: 80),
				logicalEdges: input.logicalEdges,
				impLinks: input.impLinks,
				clusterPull: pull,
			)
		default:
			options = SimOptions(
				gravity: LayoutGravity(x: 0, y: 0, strength: 0.12),
				depthAnchor: DepthAnchor(mode: .radial, strength: 0.3, spacing: 80, center: Position(x: -300, y: -300), baseRadius: 100),
				logicalEdges: input.logicalEdges,
				impLinks: input.impLinks,
				clusterPull: pull,
			)
		}
		let nodes = input.nodeIds.map { id in
			if seeded, let p = input.previousSubset[id] { return LayoutNode(id: id, x: p.x, y: p.y) }
			return LayoutNode(id: id)
		}
		var sim = try createGraphSimulation(nodes: nodes, edges: input.edges, options: options)
		sim.tick(try #require(golden["ticks"]?.intValue))
		let rows = JSONValue.array(sim.nodes.map { n in
			["id": .string(n.id), "x": .number(n.x), "y": .number(n.y), "vx": .number(n.vx), "vy": .number(n.vy)]
		})
		let actual: JSONValue = ["ticks": golden["ticks"]!, "alpha": .number(sim.alpha), "nodes": rows]
		print("layout parity drift [simulation.\(name)]: \(maxDrift(rows, golden["nodes"]!))")
		expectJSONEqual(actual, golden, tolerance: PARITY_TOLERANCE)
	}

	// "bootstrap" left parity on purpose: new clusters seed as groups apart
	// from each other (the graph opened with every cluster in one spot);
	// LayoutSettleTests pins the separation instead.
	@Test(arguments: ["full", "subset", "subsetVertical", "subsetRadial"])
	func incrementalLayoutMatchesTS(name: String) throws {
		let input = try GoldenLayoutInput()
		let golden = try #require(try Golden.load("layout.incremental")[name])
		var options = IncrementalLayoutOptions(clusters: input.clusters, logicalEdges: input.logicalEdges, impLinks: input.impLinks)
		let previous: [String: Position]
		switch name {
		case "full": previous = input.previous
		default: previous = input.previousSubset
		}
		if name == "subsetVertical" {
			options.ticks = 200
			options.depthAnchor = DepthAnchor(mode: .vertical, strength: 0.3, spacing: 80)
		} else if name == "subsetRadial" {
			options.ticks = 200
			options.depthAnchor = DepthAnchor(mode: .radial, strength: 0.3, spacing: 80, baseRadius: 100)
		}
		let out = try incrementalLayout(nodeIds: input.nodeIds, edges: input.edges, previous: previous, options: options)
		let rows = JSONValue.array(input.nodeIds.map { id in
			["id": .string(id), "x": .number(out[id]!.x), "y": .number(out[id]!.y)]
		})
		print("layout parity drift [incremental.\(name)]: \(maxDrift(rows, golden))")
		expectJSONEqual(rows, golden, tolerance: PARITY_TOLERANCE)
	}
}
