import LHCore
import SwiftUI

/// The chain table (chain-table.tsx): sessions → reasoning chains →
/// propositions, all collapsed at start; Name / Props / Created sorting;
/// fuzzy search; node-id selection with partial checkboxes and the floating
/// bar (Clear, Delete, New Session from Selection…); and per chain row,
/// "Delete chain" (your answer: the argument alone).
struct ChainTableView: View {
	@Bindable var model: GraphWindowModel
	@State private var sort = ChainSort.initial
	@State private var openGroups: Set<String> = []
	@State private var openChains: Set<String> = []

	var body: some View {
		let snap = model.snapshot
		let nodes = snap?.propositions ?? []
		let groups = chainTableGroups(nodes: nodes, chains: snap?.chains ?? [], sessions: snap?.sessions ?? [:], fileSources: snap?.fileSources ?? [:],
			query: model.query, sort: sort)
		let total = allChains(nodes, snap?.chains ?? []).count
		let searching = !model.query.jsTrimmed.isEmpty
		VStack(spacing: 0) {
			HStack {
				Text("\(total) \(total == 1 ? "chain" : "chains") · \(nodes.count) \(nodes.count == 1 ? "node" : "nodes")").foregroundStyle(.secondary)
				Spacer()
			}
			.font(.system(size: 11))
			.padding(.horizontal, 16)
			.padding(.vertical, 6)
			header
			Divider()
			if groups.isEmpty {
				Text(searching ? "No matching chains." : "No chains yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				List {
					ForEach(groups) { group in groupRows(group, open: searching || openGroups.contains(group.id)) }
				}
				.listStyle(.plain)
			}
			if !model.chainSelection.isEmpty { selectionBar(snap) }
		}
	}

	private var header: some View {
		HStack {
			sortButton("Name", .name).frame(maxWidth: .infinity, alignment: .leading)
			sortButton("Props", .props).frame(width: 60, alignment: .trailing)
			sortButton("Created", .created).frame(width: 90, alignment: .trailing)
		}
		.font(.system(size: 11, weight: .medium))
		.padding(.horizontal, 16)
		.padding(.vertical, 4)
	}

	private func sortButton(_ title: String, _ col: ChainSortColumn) -> some View {
		Button { sort = sort.clicked(col) } label: {
			HStack(spacing: 2) {
				Text(title)
				if sort.column == col { Image(systemName: sort.direction == 1 ? "chevron.up" : "chevron.down").font(.system(size: 8)) }
			}
		}
		.buttonStyle(.plain)
		.foregroundStyle(sort.column == col ? .primary : .secondary)
	}

	@ViewBuilder
	private func groupRows(_ group: ChainGroup, open: Bool) -> some View {
		HStack(spacing: 6) {
			expander(open) { toggle(&openGroups, group.id) }
			checkbox(group.nodeIds)
			Image(systemName: group.kind == .notes ? "doc.text" : open ? "folder.fill" : "folder").foregroundStyle(.secondary)
			Text(group.label ?? "unlabeled").foregroundStyle(group.label == nil ? .secondary : .primary).lineLimit(1)
			if group.kind == .notes { Text("notes").font(.system(size: 10)).foregroundStyle(.secondary) }
			Spacer()
			Text("\(group.nodeIds.count)").monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
			Text(String(group.newestCreatedAt.prefix(10))).monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
		}
		.font(.system(size: 12, weight: .medium))
		if open {
			ForEach(group.chains, id: \.id) { chain in chainRows(chain) }
		}
	}

	@ViewBuilder
	private func chainRows(_ chain: ReasoningChain) -> some View {
		let open = openChains.contains(chain.id)
		let members = chain.premises + [chain.conclusion]
		HStack(spacing: 6) {
			Color.clear.frame(width: 14)
			expander(open) { toggle(&openChains, chain.id) }
			checkbox(members)
			chainLine(chain)
			Spacer()
			Text("\(chain.premises.count + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
			Text(String((model.nodeById[chain.conclusion]?.createdAt ?? "").prefix(10))).monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
		}
		.font(.system(size: 12))
		.contextMenu {
			if !chain.premises.isEmpty {
				Button("Delete chain", role: .destructive) { model.requestDelete([chain.id]) }
			}
		}
		if open {
			ForEach(members, id: \.self) { id in
				HStack(alignment: .top, spacing: 6) {
					Color.clear.frame(width: 40)
					checkbox([id])
					VStack(alignment: .leading, spacing: 1) {
						Text(model.nodeById[id]?.name ?? id).font(.system(size: 12, weight: .medium))
						Text(model.nodeById[id]?.statement ?? "").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
					}
				}
			}
		}
	}

	private func chainLine(_ chain: ReasoningChain) -> some View {
		let name = { (id: String) in model.nodeById[id]?.name ?? id }
		var text = Text("")
		for (i, p) in chain.premises.enumerated() {
			if i > 0 { text = text + Text(" ∧ ").foregroundStyle(.secondary) }
			text = text + Text(name(p))
		}
		if !chain.premises.isEmpty { text = text + Text(" ⟹ ").foregroundStyle(.secondary) }
		return (text + Text(name(chain.conclusion)).fontWeight(.medium)).lineLimit(1).truncationMode(.tail)
	}

	private func expander(_ open: Bool, _ action: @escaping () -> Void) -> some View {
		Button(action: action) { Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 14) }
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
	}

	/// A flat node-id checkbox: on, off, or partial (some members selected).
	private func checkbox(_ ids: [String]) -> some View {
		let count = ids.filter(model.chainSelection.contains).count
		let state = count == 0 ? "square" : count == ids.count ? "checkmark.square.fill" : "minus.square.fill"
		return Button {
			if count == ids.count { model.chainSelection.subtract(ids) } else { model.chainSelection.formUnion(ids) }
		} label: { Image(systemName: state) }
			.buttonStyle(.plain)
			.foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
	}

	private func selectionBar(_ snap: GraphSnapshot?) -> some View {
		let ids = Array(model.chainSelection)
		let chains = chainsForSelection(ids, snap?.chains ?? []).filter { !$0.premises.isEmpty }.count
		return HStack(spacing: 10) {
			Text("\(ids.count) \(ids.count == 1 ? "node" : "nodes") → \(chains) \(chains == 1 ? "chain" : "chains")").monospacedDigit()
			Spacer()
			Button("Clear") { model.chainSelection = [] }
			Button("New Session from Selection…") { model.startSession(from: model.chainSelection) }
			Button("Delete", role: .destructive) { model.requestDelete(ids) }
				.foregroundStyle(.red)
		}
		.font(.system(size: 12))
		.padding(10)
		.background(.bar)
		.overlay(alignment: .top) { Divider() }
	}

	private func toggle(_ set: inout Set<String>, _ id: String) {
		if set.contains(id) { set.remove(id) } else { set.insert(id) }
	}
}

/// delete-node-dialog.tsx: names (up to 8), the permanence line, Cancel / Delete.
struct DeleteNodeSheet: View {
	@Bindable var model: GraphWindowModel
	@State private var busy = false

	var body: some View {
		let ids = model.deleteTargets
		let isChain = ids.count == 1 && isImpNodeId(ids[0])
		let names = ids.map { id in isChain ? chainName(id) : (model.nodeById[id]?.name ?? id) }
		VStack(alignment: .leading, spacing: 12) {
			Text(isChain ? "Delete chain?" : ids.count == 1 ? "Delete node?" : "Delete \(ids.count) nodes?").font(.headline)
			Text(names.prefix(8).joined(separator: ", ") + (names.count > 8 ? ", and \(names.count - 8) more" : "")).font(.system(.body, design: .monospaced))
			Text(isChain ? "This permanently deletes the argument; its propositions and other chains stay — this cannot be undone."
				: ids.count == 1 ? "This permanently deletes the node — this cannot be undone."
				: "This permanently deletes all \(ids.count) nodes — this cannot be undone.")
				.foregroundStyle(.secondary)
			if let error = model.deleteError { Text(error).foregroundStyle(.red) }
			HStack {
				Spacer()
				Button("Cancel", role: .cancel) { model.deleteTargets = [] }.keyboardShortcut(.cancelAction).disabled(busy)
				Button(busy ? "Deleting…" : model.deleteError == nil ? "Delete" : "Try again", role: .destructive) {
					busy = true
					Task {
						_ = await model.confirmDelete()
						busy = false
					}
				}
				.keyboardShortcut(.defaultAction)
				.disabled(busy)
			}
		}
		.padding(20)
		.frame(width: 420)
	}

	private func chainName(_ id: String) -> String {
		guard let c = model.snapshot?.chains.first(where: { $0.id == id }) else { return id }
		let n = { (x: String) in model.nodeById[x]?.name ?? x }
		return c.premises.map(n).joined(separator: " ∧ ") + " ⟹ " + n(c.conclusion)
	}
}
