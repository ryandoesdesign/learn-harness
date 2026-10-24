import Foundation
import LHCore
import LHMarkdown
import Observation

/// Session Find (port of components/session-find.tsx): literal,
/// case-insensitive, per text unit, in reading order. The session model
/// supplies the units (only what is visible — collapsed sections stay out);
/// views read highlights back by unit id.
@MainActor
@Observable
final class FindModel {
	struct Match: Hashable {
		var unitId: String
		/// The transcript row the unit lives in (the scroll target).
		var rowId: String
		var range: SessionTextMatch
	}

	struct Unit {
		var unit: FindUnit
		var rowId: String
	}

	var isOpen = false
	var query = "" { didSet { if query != oldValue { recompute(jump: true) } } }
	private(set) var matches: [Match] = []
	private(set) var active = -1
	/// Bumped when the active match changes; the transcript scrolls to it.
	private(set) var scrollTick = 0
	/// Bumped to (re)select the field's text (a second ⌘F).
	private(set) var focusTick = 0

	private var units: [Unit] = []
	private var byUnit: [String: [(SessionTextMatch, Int)]] = [:]

	func open() {
		isOpen = true
		focusTick += 1
	}

	func close() { isOpen = false }

	/// Reset for a new session (state persists while closed, resets on switch).
	func reset() {
		isOpen = false
		query = ""
		units = []
		recompute(jump: false)
	}

	/// New visible units (streaming, expand/collapse): keep the active match
	/// when it still exists.
	func setUnits(_ next: [Unit]) {
		units = next
		recompute(jump: false)
	}

	func step(_ direction: Int) {
		guard !matches.isEmpty else { return }
		active = stepSessionMatch(active, matches.count, direction)
		scrollTick += 1
	}

	var activeMatch: Match? { matches.indices.contains(active) ? matches[active] : nil }

	/// (range, isActive) for one unit's text.
	func highlights(_ unitId: String) -> [(SessionTextMatch, Bool)] {
		guard isOpen, let list = byUnit[unitId] else { return [] }
		return list.map { ($0.0, $0.1 == active) }
	}

	private func recompute(jump: Bool) {
		let previous = activeMatch
		var next: [Match] = []
		for u in units {
			for r in findMatches(in: u.unit.text, query: query, preformatted: u.unit.preformatted) {
				next.append(Match(unitId: u.unit.id, rowId: u.rowId, range: r))
			}
		}
		matches = next
		var index: [String: [(SessionTextMatch, Int)]] = [:]
		for (i, m) in next.enumerated() { index[m.unitId, default: []].append((m.range, i)) }
		byUnit = index
		if jump {
			active = next.isEmpty ? -1 : 0
			if !next.isEmpty { scrollTick += 1 }
		} else if let previous, let same = next.firstIndex(of: previous) {
			active = same
		} else {
			active = next.isEmpty ? -1 : min(max(active, 0), next.count - 1)
		}
	}
}
