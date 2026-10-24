import Foundation

// Port of src/core/phases.ts — phase derivation from EXPLICIT EVENTS, never
// occupancy (docs/probe-teach-split.md §4):
//
//   probe — until the prober's `probe_done` call CONCLUDES (a clean
//           toolResult for it)
//   plan  — probe concluded, until teaching actually BEGINS
//   teach — the first quiz/explain CALL tagged with a `nodeId` (probe
//           quizzes carry no nodeId, so nothing false-triggers). The CALL
//           is the seam, not its answer.
//
// Strictly sequential. The TS view-part fold (`phaseAt3` over
// `PhaseMessage` parts) is the UI dialect; this file ports the NATIVE fold
// (`phaseAt3Lh`) and adapts `phaseTimeline` / `teachStepIndex` to `Message`.

/// A quiz call's input carries a non-empty string `nodeId` iff it is tagged
/// (teach-only — the probe quiz schema has no nodeId field).
private func taggedNodeId(_ input: JSONValue) -> Bool {
	guard let id = input["nodeId"]?.stringValue else { return false }
	return !id.isEmpty
}

/// Is this call a nodeId-tagged quizzing call (quiz OR explain)?
private func isTaggedQuizCall(_ call: ToolUse) -> Bool {
	(call.name == "quiz" || call.name == "explain") && taggedNodeId(call.input)
}

/// One message's advance of the phase (pure fold step): probe→plan at the
/// probe_done call's clean toolResult; plan→teach at the assistant message
/// carrying the first nodeId-tagged quiz/explain CALL.
private func advance(_ phase: Phase3, _ m: Message) -> Phase3 {
	switch m.body {
	case .toolResult(let r):
		if phase == .probe && r.toolName == "probe_done" && !r.isError { return .plan }
	case .assistant(let a):
		if phase == .plan && a.toolUses.contains(where: isTaggedQuizCall) { return .teach }
	default:
		break
	}
	return phase
}

/// The phase at `upToIndex` (inclusive; default: the last message) of a
/// native record.
public func phaseAt3Lh(_ messages: [Message], upToIndex: Int? = nil) -> Phase3 {
	var phase = Phase3.probe
	let last = Swift.min(upToIndex ?? messages.count - 1, messages.count - 1)
	guard last >= 0 else { return phase }
	for i in 0...last { phase = advance(phase, messages[i]) }
	return phase
}

/// The phase at EVERY message index, in one forward fold (the transcript
/// dividers render one per boundary — per-index `phaseAt3Lh` would be
/// quadratic). `out[i] == phaseAt3Lh(messages, upToIndex: i)` for every i.
public func phaseTimeline(_ messages: [Message]) -> [Phase3] {
	var out: [Phase3] = []
	out.reserveCapacity(messages.count)
	var phase = Phase3.probe
	for m in messages {
		phase = advance(phase, m)
		out.append(phase)
	}
	return out
}

/// WHERE inside the flipping group teaching begins (owner round 8,
/// 2026-10-05 — the stacked-dividers bug): plan→teach flips at the first
/// tagged quiz/explain CALL, but the plan PRESENTATION often lives in the
/// same assistant group, an earlier provider STEP than the call.
///
/// Native adaptation: `group` is the native slice one assistant view group
/// projects from (its assistant messages plus folded tool results). Each
/// assistant message with content is one provider STEP (the view's
/// step-start). Returns -1 when the first tagged call sits in the group's
/// FIRST step (the divider belongs before the whole group) or there is no
/// tagged call; otherwise the index into `group` of the step message whose
/// generation contains the call (the divider renders at that boundary).
public func teachStepIndex(_ group: [Message]) -> Int {
	var steps = 0
	for (i, m) in group.enumerated() {
		guard let a = m.assistant, !a.content.isEmpty else { continue }
		steps += 1
		if a.toolUses.contains(where: isTaggedQuizCall) {
			return steps <= 1 ? -1 : i
		}
	}
	return -1
}
