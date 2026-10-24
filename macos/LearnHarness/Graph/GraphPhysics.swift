import Foundation
import LHCore

/// The graph window's live d3-force simulation (docs/native-macos-m7.md),
/// off the main thread: the window sends drag pins as messages and gets
/// position frames back at up to 60 Hz. It runs only while hot — an idle
/// graph costs nothing. TS renderer constants: live decay 0.05, drag target
/// 0.3, settled below alpha 0.005.
actor GraphPhysics {
	struct Frame: Sendable {
		/// Positions in load order.
		var positions: [SIMD2<Double>]
		/// The sim came to rest after a drag (the window commits).
		var settledAfterDrag: Bool
	}

	nonisolated let frames: AsyncStream<Frame>
	private let continuation: AsyncStream<Frame>.Continuation
	private var sim: GraphSimulation?
	private var index: [String: Int] = [:]
	private var loop: Task<Void, Never>?
	private var dragged = false

	init() {
		(frames, continuation) = AsyncStream<Frame>.makeStream(bufferingPolicy: .bufferingNewest(1))
	}

	/// (Re)build at the given positions; starts at the settle floor so the
	/// first drag reheats gently (TS buildSim hygiene). `reheat` = alpha 1
	/// (a physics-settings change re-anneals the whole graph).
	func load(ids: [String], positions: [SIMD2<Double>], edges: [LayoutEdge], options: SimOptions, reheat: Bool) {
		let pinned = sim.map { s in Dictionary(s.nodes.compactMap { n in n.fx.map { (n.id, SIMD2($0, n.fy ?? n.y)) } }, uniquingKeysWith: { a, _ in a }) } ?? [:]
		let nodes = zip(ids, positions).map { id, p in LayoutNode(id: id, x: p.x, y: p.y, fx: pinned[id]?.x, fy: pinned[id]?.y) }
		guard !nodes.isEmpty, var s = try? createGraphSimulation(nodes: nodes, edges: edges, options: options) else {
			sim = nil
			index = [:]
			return
		}
		s.alpha = reheat ? 1 : GraphCanvasConstants.simSettleAlpha
		sim = s
		index = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
		if reheat { run() }
	}

	/// A press on a node: pin it where the pointer is and reheat.
	func pin(_ id: String, at p: SIMD2<Double>) {
		guard let i = index[id], sim != nil else { return }
		sim!.nodes[i].fx = p.x
		sim!.nodes[i].fy = p.y
		sim!.alphaTarget = GraphCanvasConstants.dragAlphaTarget
		dragged = true
		run()
	}

	/// The release: unpin and anneal to rest.
	func release(_ id: String) {
		guard let i = index[id], sim != nil else { return }
		sim!.nodes[i].fx = nil
		sim!.nodes[i].fy = nil
		sim!.alphaTarget = 0
		run()
	}

	private func run() {
		guard loop == nil else { return }
		loop = Task { [weak self] in await self?.spin() }
	}

	private func spin() async {
		defer { loop = nil }
		while var s = sim, s.alpha >= GraphCanvasConstants.simSettleAlpha || s.alphaTarget > 0 {
			if Task.isCancelled { return }
			s.tick()
			sim = s
			continuation.yield(Frame(positions: s.nodes.map(\.position), settledAfterDrag: false))
			try? await Task.sleep(for: .milliseconds(16))
		}
		if let s = sim {
			continuation.yield(Frame(positions: s.nodes.map(\.position), settledAfterDrag: dragged))
			dragged = false
		}
	}
}
