import { readJson, readJsonl } from "./_fixtures.ts";
import { settleGraphLayout } from "../../src/core/layout-settle.ts";
import type { GraphChain, GraphNode, Position } from "../../src/core/contracts.ts";

/** The merge-time settle over the golden ledgers + positions ledger. */
export default () => {
	let written: Record<string, Position> = {};
	settleGraphLayout({
		readNodes: () => readJsonl<GraphNode>("graph/nodes.jsonl"),
		readChains: () => readJsonl<GraphChain>("graph/chains.jsonl"),
		readPositions: () => readJson<{ positions: Record<string, Position> }>("graph/positions.json").positions,
		writePositions: (p) => {
			written = p;
		},
	});
	return { "layout.settle": written };
};
