import Foundation

// Port of src/core/plan-blocks.ts — the plan presentation seam
// (docs/probe-teach-split.md §6). The plan renders IN FLOW once, at
// authoring: a frozen snapshot carried by a native plan-block MARKER
// appended at the turn's persist (idempotent per plan_init call). Statuses
// are derived AT EMISSION time from the transcript — the block never
// re-derives.

extension PlanBlockData {
	/// The marker's `details.block` JSON, in the TS key order
	/// (`current` is an explicit null before any tagged call).
	public var blockJSON: JSONValue {
		.object(JSONObject(pairs: [
			("kind", .string(kind)),
			("at", .string(at)),
			("current", current.map(JSONValue.string) ?? .null),
			("nodes", .array(nodes.map { ["id": .string($0.id), "title": .string($0.title), "status": .string($0.status.rawValue)] })),
			("edges", .array(edges.map { ["from": .string($0.from), "to": .string($0.to)] })),
		]))
	}
}

/// The snapshot payload: statuses derived from the NATIVE transcript (quiz
/// CALLS only — results feed nothing). `at` is `now` as JS `toISOString`.
func planBlockSnapshot(_ tree: PlanTree, _ messages: [Message], now: Date) -> PlanBlockData {
	let statuses = derivePlanStatuses(tree, messages)
	return PlanBlockData(
		kind: "full",
		at: jsISOString(now),
		current: statuses.current,
		nodes: tree.nodes.map { PlanBlockData.Node(id: $0.id, title: $0.title, status: derivedNodeStatus(statuses, $0.id)) },
		edges: tree.edges.map { PlanEdge(from: $0.from, to: $0.to) })
}

/// The record's plan-block markers, keyed by the plan_init call they
/// present — the idempotency set for emission.
public func emittedPlanBlockCalls(_ messages: [Message]) -> Set<String> {
	var out = Set<String>()
	for m in messages {
		guard let marker = m.marker, marker.kind == .planBlock,
			let id = marker.details["planCallId"]?.stringValue else { continue }
		out.insert(id)
	}
	return out
}

/// The native emission seam (pure): ONE plan-block marker per TURN — for the
/// turn's LAST successful plan_init call (a same-turn rewrite presents once;
/// a later turn's rewrite gets its own block) that the record hasn't already
/// emitted. `tree` is the record's current tree; `transcript` is the full
/// native transcript the status derivation reads. `now` stamps the
/// snapshot's `at` and the marker.
public func planBlocksFor(
	record: [Message],
	newMessages: [Message],
	tree: PlanTree?,
	transcript: [Message],
	now: Date = Date()
) -> [Message] {
	guard let tree, !tree.nodes.isEmpty else { return [] }
	let emitted = emittedPlanBlockCalls(record)
	var last: String?
	for m in newMessages {
		guard let r = m.toolResult, r.toolName == "plan_init" else { continue }
		guard r.details?["ok"]?.boolValue == true else { continue }
		if emitted.contains(r.toolUseId) { continue }
		last = r.toolUseId
	}
	guard let last else { return [] }
	let snapshot = planBlockSnapshot(tree, transcript, now: now)
	return [newPlanBlockMessage(planCallId: last, block: snapshot.blockJSON, now: jsMillis(now))]
}

/// JS `Date.now()`-style integer milliseconds.
private func jsMillis(_ date: Date) -> Int {
	Int((date.timeIntervalSince1970 * 1000).rounded(.down))
}

/// JS `Date.prototype.toISOString` (UTC, millisecond precision; expanded
/// ±YYYYYY years outside 0…9999).
private func jsISOString(_ date: Date) -> String {
	let ms = jsMillis(date)
	var days = ms >= 0 ? ms / 86_400_000 : (ms - 86_399_999) / 86_400_000
	let msOfDay = ms - days * 86_400_000
	// Civil-from-days (Howard Hinnant).
	days += 719_468
	let era = (days >= 0 ? days : days - 146_096) / 146_097
	let doe = days - era * 146_097
	let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
	let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
	let mp = (5 * doy + 2) / 153
	let day = doy - (153 * mp + 2) / 5 + 1
	let month = mp < 10 ? mp + 3 : mp - 9
	let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
	func pad(_ v: Int, _ w: Int) -> String {
		let s = String(v)
		return String(repeating: "0", count: Swift.max(0, w - s.count)) + s
	}
	let y = (0...9999).contains(year) ? pad(year, 4) : (year < 0 ? "-" : "+") + pad(abs(year), 6)
	let h = msOfDay / 3_600_000, mi = msOfDay / 60_000 % 60, s = msOfDay / 1000 % 60, f = msOfDay % 1000
	return "\(y)-\(pad(month, 2))-\(pad(day, 2))T\(pad(h, 2)):\(pad(mi, 2)):\(pad(s, 2)).\(pad(f, 3))Z"
}
