import { readJson, readJsonl } from "./_fixtures.ts";
import type { GraphChain, GraphNode, Position } from "../../src/core/contracts.ts";
import { deriveView, getGraph } from "../../src/core/graph.ts";
import { attachImpToCommunities, birthSessionPartition } from "../../src/core/session-clusters.ts";
import {
	createGraphSimulation,
	incrementalLayout,
	inferenceDepths,
	type IncrementalLayoutOptions,
	type LayoutNode,
	type SimOptions,
} from "../../src/core/layout.ts";

/** The layout engine over the golden graph. The INPUT (what layout-settle
 *  hands incrementalLayout: the derived view, the birth-session partition
 *  with imp nodes attached, the positions ledger) is dumped too, so the
 *  Swift side does not depend on the graph port. */
export default () => {
	const graph = getGraph({
		readNodes: () => readJsonl<GraphNode>("graph/nodes.jsonl"),
		readChains: () => readJsonl<GraphChain>("graph/chains.jsonl"),
	});
	const view = deriveView(graph);
	const communities = birthSessionPartition(graph.nodes);
	attachImpToCommunities(communities, graph.nodes, graph.chains);
	const clusters = communities.map((c) => c.members);
	const ledger = readJson<{ positions: Record<string, Position> }>("graph/positions.json").positions;
	const nodeIds = view.nodes.map((n) => n.id);
	// The full ledger, restricted to live nodes (in node order), and a
	// subset (every other one) — the second warm start exercises neighbour
	// seeding and rim seeds for the dropped half.
	const previous: Record<string, Position> = {};
	for (const id of nodeIds) if (ledger[id]) previous[id] = ledger[id]!;
	const previousSubset: Record<string, Position> = {};
	Object.keys(previous).forEach((id, i) => {
		if (i % 2 === 0) previousSubset[id] = previous[id]!;
	});

	const input = {
		nodeIds,
		edges: view.edges,
		logicalEdges: view.logicalEdges,
		impLinks: view.impLinks,
		clusters,
		previous,
		previousSubset,
	};

	const propositionIds = nodeIds.filter((id) => !id.startsWith("arg_"));
	const depths = Object.fromEntries(inferenceDepths(propositionIds.map((id) => ({ id })), view.logicalEdges));

	// Fixed-tick simulation runs. `seeded` = start from the ledger (missing
	// nodes left unplaced → d3's phyllotaxis); otherwise every node starts
	// on the spiral.
	const simCases: Array<{ name: string; ticks: number; seeded: boolean; options: SimOptions }> = [
		{
			name: "off",
			ticks: 120,
			seeded: false,
			options: {
				gravity: { x: 0, y: 0, strength: 0.12 },
				clusterPull: { clusters: communities, strength: 0.15 },
			},
		},
		{
			name: "live",
			ticks: 60,
			seeded: true,
			options: {
				gravity: { x: 10, y: -20, strength: 0.12 },
				clusterPull: { clusters: communities, strength: 0.15 },
				alphaDecay: 0.05,
				velocityDecay: 0.3,
				linkDistance: 55,
				linkStrength: 0.7,
				chargeStrength: -180,
			},
		},
		{
			name: "vertical",
			ticks: 150,
			seeded: true,
			options: {
				gravity: { x: 0, y: 0, strength: 0.12 },
				clusterPull: { clusters: communities, strength: 0.15 },
				depthAnchor: { mode: "vertical", strength: 0.3, spacing: 80 },
				logicalEdges: view.logicalEdges,
				impLinks: view.impLinks,
			},
		},
		{
			name: "radial",
			ticks: 150,
			seeded: true,
			options: {
				gravity: { x: 0, y: 0, strength: 0.12 },
				clusterPull: { clusters: communities, strength: 0.15 },
				depthAnchor: { mode: "radial", strength: 0.3, spacing: 80, baseRadius: 100, center: { x: -300, y: -300 } },
				logicalEdges: view.logicalEdges,
				impLinks: view.impLinks,
			},
		},
	];
	const simulation: Record<string, unknown> = {};
	for (const c of simCases) {
		const nodes: LayoutNode[] = nodeIds.map((id) => {
			const p = c.seeded ? previousSubset[id] : undefined;
			return p ? { id, x: p.x, y: p.y } : { id };
		});
		const sim = createGraphSimulation(nodes, view.edges, c.options);
		for (let i = 0; i < c.ticks; i++) sim.tick();
		simulation[c.name] = {
			ticks: c.ticks,
			alpha: sim.alpha(),
			nodes: sim.nodes().map((n) => ({ id: n.id, x: n.x, y: n.y, vx: n.vx, vy: n.vy })),
		};
	}

	// incrementalLayout as layout-settle calls it, over several ledgers.
	const settle: IncrementalLayoutOptions = {
		clusters: communities,
		logicalEdges: view.logicalEdges,
		impLinks: view.impLinks,
	};
	const incCases: Array<{ name: string; previous: Record<string, Position>; options: IncrementalLayoutOptions }> = [
		{ name: "full", previous, options: settle },
		{ name: "subset", previous: previousSubset, options: settle },
		{ name: "bootstrap", previous: {}, options: settle },
		{
			name: "subsetVertical",
			previous: previousSubset,
			options: { ...settle, ticks: 200, depthAnchor: { mode: "vertical", strength: 0.3, spacing: 80 } },
		},
		{
			name: "subsetRadial",
			previous: previousSubset,
			options: { ...settle, ticks: 200, depthAnchor: { mode: "radial", strength: 0.3, spacing: 80, baseRadius: 100 } },
		},
	];
	const incremental: Record<string, unknown> = {};
	for (const c of incCases) {
		const out = incrementalLayout(view.nodes, view.edges, new Map(Object.entries(c.previous)), c.options);
		incremental[c.name] = [...out].map(([id, p]) => ({ id, x: p.x, y: p.y }));
	}

	return {
		"layout.input": input,
		"layout.depths": depths,
		"layout.simulation": simulation,
		"layout.incremental": incremental,
	};
};
