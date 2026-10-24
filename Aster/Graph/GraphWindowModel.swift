import AppKit
import CryptoKit
import Foundation
import LHAgent
import LHCore
import LHStore
import Observation

/// The knowledge graph window's state (docs/native-macos-m7.md): the
/// snapshot (re-read on every graph revision), live positions from the
/// physics actor, the render settings, the camera, search, the detail card,
/// the chain table, deletion and import.
@MainActor
@Observable
final class GraphWindowModel {
	let app: AppModel
	let physics = GraphPhysics()

	private(set) var snapshot: GraphSnapshot?
	/// Snapshot node ids, in physics load order, and their live positions.
	private(set) var ids: [String] = []
	private(set) var positions: [SIMD2<Double>] = []
	private(set) var indexById: [String: Int] = [:]
	private(set) var nodeById: [String: GraphNode] = [:]
	/// Bumped when nodes, positions or visibility change (the canvas rebuilds caches).
	private(set) var geometryVersion = 0
	/// Bumped on data or settings changes (labels re-wrap).
	private(set) var dataVersion = 0
	private(set) var costs: GraphCostSummary?
	private(set) var simActive = false

	var settings = DEFAULT_RENDER_SETTINGS {
		didSet { if settings != oldValue { settingsChanged(physics: settings.physics != oldValue.physics) } }
	}
	var query = "" {
		didSet { if query != oldValue { visibilityChanged() } }
	}
	/// The detail card's node and where it opened (view coordinates).
	var selected: (id: String, at: CGPoint)?
	var showChains = false
	var chainSelection: Set<String> = []
	var deleteTargets: [String] = []
	var deleteError: String?
	var importErrors: [ExtractionService.NotesResult] = []
	var importing = false
	/// The canvas asks to be redrawn.
	var redraw: () -> Void = {}
	/// The canvas's camera commands (⌘= / ⌘- / ⌘0).
	var zoomBy: (Double) -> Void = { _ in }
	var fit: () -> Void = {}

	private var settingsSave: Task<Void, Never>?
	private var commitTask: Task<Void, Never>?
	/// The open-time repair is annealing (its rest refits the camera and
	/// remembers the layout it committed).
	private var repairing = false
	private static let repairedKey = "aster.graph.repaired.v1"

	/// Physics commands, applied strictly in order (a release can never
	/// overtake its pin).
	private enum PhysicsCommand: Sendable {
		case load(ids: [String], positions: [SIMD2<Double>], edges: [LayoutEdge], options: SimOptions, reheat: Bool, commit: Bool)
		case pin(String, SIMD2<Double>)
		case release(String)
	}
	private let commands: AsyncStream<PhysicsCommand>.Continuation

	init(app: AppModel) {
		self.app = app
		let (stream, continuation) = AsyncStream<PhysicsCommand>.makeStream()
		commands = continuation
		let physics = physics
		Task {
			for await command in stream {
				switch command {
				case .load(let ids, let positions, let edges, let options, let reheat, let commit):
					await physics.load(ids: ids, positions: positions, edges: edges, options: options, reheat: reheat, commit: commit)
				case .pin(let id, let p): await physics.pin(id, at: p)
				case .release(let id): await physics.release(id)
				}
			}
		}
		settings = sanitizeRenderSettings((try? SettingsRepository(app.database).readRenderSettings()) ?? nil)
		// The one consumer of the physics frames (an AsyncStream takes one).
		Task { [weak self, frames = physics.frames] in
			for await frame in frames { self?.apply(frame) }
		}
	}

	var isEmpty: Bool { snapshot.map { $0.propositions.isEmpty } ?? true }
	var renderingEnabled: Bool { LHCore.renderingEnabled(resolveSettings((try? SettingsRepository(app.database).read()) ?? nil, catalog: app.catalog).graph) }

	/// Visible proposition ids (nil = all) — search filters draw, picking, labels, regions.
	private(set) var visible: Set<String>?

	// MARK: Data

	func observe() async {
		do {
			for try await _ in GraphRepository(app.database).observeRevision() { reload() }
		} catch {}
	}

	func reload() {
		let db = app.database
		let snap = graphSnapshot(GraphDeps(chatStore: ChatRepository(db), graphStore: GraphRepository(db)))
		snapshot = snap
		nodeById = Dictionary(snap.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
		ids = snap.nodes.map(\.id)
		indexById = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
		var stored = snap.positions ?? [:]
		if stored.isEmpty, !ids.isEmpty {
			stored = (try? incrementalLayout(nodeIds: ids, edges: snap.edges, previous: [:], options: IncrementalLayoutOptions(
				clusters: snap.clusters.map(\.members), logicalEdges: snap.logicalEdges, impLinks: snap.impLinks))) ?? [:]
		} else {
			stored = seedMissingNodePositions(ids, stored)
		}
		positions = ids.map { id in stored[id].map { SIMD2($0.x, $0.y) } ?? SIMD2(0, 0) }
		if let sel = selected, nodeById[sel.id] == nil { selected = nil }
		chainSelection = chainSelection.filter { nodeById[$0] != nil }
		costs = loadCosts()
		recomputeVisible()
		dataVersion += 1
		geometryVersion += 1
		// Clusters stacked on one another (a layout settled before new
		// sessions seeded apart): anneal them apart now and commit the rest —
		// once per layout, since linked clusters can rightly overlap.
		let repair = clustersOverlap(snap.clusters.map(\.members), positions: stored)
			&& Self.fingerprint(snap.positions ?? [:]) != UserDefaults.standard.string(forKey: Self.repairedKey)
		if repair {
			repairing = true
			simActive = true
		}
		rebuildPhysics(reheat: repair, commit: repair)
		redraw()
	}

	/// A session rename relabels its cluster without touching the sim (a
	/// drag in progress is never cancelled).
	func sessionsChanged(_ sessions: [ChatSummary]) {
		guard var snap = snapshot else { return }
		var changed = false
		for s in sessions where snap.sessions[s.id] != nil && snap.sessions[s.id] != s.title {
			snap.sessions[s.id] = s.title
			for i in snap.clusters.indices where snap.clusters[i].id == s.id && snap.clusters[i].label != nil { snap.clusters[i].label = s.title }
			changed = true
		}
		guard changed else { return }
		snapshot = snap
		dataVersion += 1
		redraw()
	}

	private func loadCosts() -> GraphCostSummary {
		let chats = ChatRepository(app.database)
		let runs: [CostSummaryInput.ChatRuns] = chats.listChats().compactMap { summary in
			guard let record = (try? chats.get(summary.id)) ?? nil, let ex = record.extractions, !ex.isEmpty else { return nil }
			return .init(title: record.title, extractions: ex)
		}
		let sources = GraphRepository(app.database).readSources().compactMap { s in s.extractions.map { CostSummaryInput.SourceRuns(filePath: s.filePath, extractions: $0) } }
		return graphCostSummary(CostSummaryInput(chats: runs, sources: sources), catalog: app.catalog)
	}

	// MARK: Physics

	private var simCenter: SIMD2<Double> {
		guard let b = GraphBBox(positions.map { GraphPoint(x: $0.x, y: $0.y) }) else { return .zero }
		return SIMD2((b.minX + b.maxX) / 2, (b.minY + b.maxY) / 2)
	}

	private func rebuildPhysics(reheat: Bool, commit: Bool = false) {
		guard let snap = snapshot else { return }
		let t = settings.physics
		let center = simCenter
		let options = SimOptions(
			linkDistance: t.linkDistance, linkStrength: t.linkStrength, chargeStrength: t.chargeStrength,
			gravity: LayoutGravity(x: center.x, y: center.y, strength: t.gravity),
			alphaDecay: GraphCanvasConstants.liveAlphaDecay, velocityDecay: t.velocityDecay,
			depthAnchor: t.depthMode == .off ? nil : DepthAnchor(mode: t.depthMode, strength: t.depthStrength, spacing: t.depthSpacing,
				center: Position(x: center.x, y: center.y), baseRadius: t.depthBaseRadius),
			logicalEdges: snap.logicalEdges, impLinks: snap.impLinks,
			clusterPull: snap.clusters.isEmpty ? nil : ClusterPull(clusters: snap.clusters.map(\.members), strength: t.clusterPull))
		let (ids, positions, edges) = (ids, positions, snap.edges)
		commands.yield(.load(ids: ids, positions: positions, edges: edges, options: options, reheat: reheat, commit: commit))
	}

	private func apply(_ frame: GraphPhysics.Frame) {
		guard frame.positions.count == positions.count else { return }
		positions = frame.positions
		simActive = !frame.commit
		geometryVersion += 1
		redraw()
		guard frame.commit else { return }
		let repaired = repairing
		if repairing {
			repairing = false
			fit()
		}
		scheduleCommit(repaired: repaired)
	}

	func position(_ id: String) -> SIMD2<Double>? { indexById[id].map { positions[$0] } }

	/// Drag: pin the node under the pointer (a new drag cancels a pending commit).
	func drag(_ id: String, to world: SIMD2<Double>) {
		commitTask?.cancel()
		simActive = true
		if let i = indexById[id] { positions[i] = world }
		commands.yield(.pin(id, world))
	}

	func endDrag(_ id: String) { commands.yield(.release(id)) }

	/// The settled drag or repair, 250 ms later: commitPositions (sanitize,
	/// clamp, re-settle). A repair remembers the layout it stored.
	private func scheduleCommit(repaired: Bool = false) {
		commitTask?.cancel()
		let all = Dictionary(zip(ids, positions).map { ($0, Position(x: $1.x, y: $1.y)) }, uniquingKeysWith: { a, _ in a })
		let db = app.database
		commitTask = Task {
			try? await Task.sleep(for: .seconds(GraphCanvasConstants.commitDebounce))
			guard !Task.isCancelled else { return }
			let stored = (try? commitPositions(all, store: GraphRepository(db))) ?? [:]
			if repaired, !stored.isEmpty {
				UserDefaults.standard.set(Self.fingerprint(GraphRepository(db).readPositions()), forKey: Self.repairedKey)
			}
		}
	}

	/// A stable digest of a positions ledger (ids sorted, coordinates to
	/// 1e-3) — the repair's "already done" mark.
	private static func fingerprint(_ positions: [String: Position]) -> String {
		let text = positions.sorted { $0.key < $1.key }.map { String(format: "%@:%.3f,%.3f", $0.key, $0.value.x, $0.value.y) }.joined(separator: ";")
		return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
	}

	// MARK: Settings and search

	private func settingsChanged(physics: Bool) {
		dataVersion += 1
		geometryVersion += 1
		if physics { rebuildPhysics(reheat: true) }
		redraw()
		settingsSave?.cancel()
		let json = settings.json, db = app.database
		settingsSave = Task {
			try? await Task.sleep(for: .milliseconds(400))
			guard !Task.isCancelled else { return }
			try? SettingsRepository(db).writeRenderSettings(json)
		}
	}

	private func visibilityChanged() {
		recomputeVisible()
		if let sel = selected, visible.map({ !$0.contains(sel.id) }) ?? false { selected = nil }
		dataVersion += 1
		geometryVersion += 1
		redraw()
	}

	private func recomputeVisible() {
		let q = query.jsTrimmed
		guard !q.isEmpty, let snap = snapshot else { visible = nil; return }
		visible = Set(snap.propositions.filter { isNodeVisible(name: $0.name, statement: $0.statement, query: q) }.map(\.id))
	}

	func isVisible(_ id: String) -> Bool {
		guard let visible else { return true }
		// An implication node shows when all its endpoints do.
		if isImpNodeId(id), let link = snapshot?.impLinks.first(where: { $0.id == id }) {
			return (link.premises + [link.conclusion]).allSatisfy(visible.contains)
		}
		return visible.contains(id)
	}

	var noMatches: Bool { visible?.isEmpty == true }

	// MARK: Actions

	func requestDelete(_ ids: [String]) {
		deleteError = nil
		deleteTargets = ids
	}

	func confirmDelete() async -> Bool {
		if let error = await app.deleteGraphNodes(deleteTargets) {
			deleteError = error
			return false
		}
		chainSelection.subtract(deleteTargets)
		deleteTargets = []
		return true
	}

	func importNotes() async {
		importing = true
		importErrors = await app.importNotes()
		importing = false
	}

	/// New Session / Practice from Selection… (the chain table's picks).
	func startSession(from ids: Set<String>, kind: ChatKind? = nil) {
		let picks = picks(from: ids)
		guard !picks.isEmpty else { return }
		app.newSession(picks: picks, kind: kind)
	}

	/// The selection as draft picks, by name (implicit nodes left out).
	func picks(from ids: Set<String>) -> [GraphContextPick] {
		ids.compactMap { nodeById[$0] }.filter { !isImpNodeId($0.id) }
			.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
			.map { GraphContextPick(id: $0.id, name: $0.name, statement: $0.statement) }
	}

	/// The detail card's sessions: chats link, files are plain.
	func sessions(of id: String) -> [(id: String, title: String, isFile: Bool)] {
		guard let snap = snapshot, let node = nodeById[id] else { return [] }
		var seen = Set<String>()
		return node.provenance.map(\.chatId).filter { seen.insert($0).inserted }.compactMap { cid in
			if let title = snap.sessions[cid] { return (cid, title, false) }
			if let path = snap.fileSources[cid] { return (cid, path, true) }
			return nil
		}
	}

	/// The first message this node came from in a chat (the link's anchor).
	func anchor(of id: String, in chatId: String) -> String? {
		nodeById[id]?.provenance.first { $0.chatId == chatId && !$0.messageId.isEmpty }?.messageId
	}

	func open(chat chatId: String, node id: String) {
		app.selection = chatId
		if let m = anchor(of: id, in: chatId) { app.session?.scrollTo(messageId: m) }
		NSApp.windows.first { $0.canBecomeMain && $0.isVisible && !($0.identifier?.rawValue.contains("graph") ?? false) }?.makeKeyAndOrderFront(nil)
	}
}
