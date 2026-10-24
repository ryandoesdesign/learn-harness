import Foundation

// The VIEW dialect of src/core/phases.ts (`phaseAt3` / `phaseTimeline` /
// `teachStepIndex` over view parts) plus plan-block.tsx `latestTree`. The
// transcript indexes phases per VIEW message (chat.tsx `phases[mi]`); the
// native fold in Session/Phases.swift serves the record side.

/// A quiz/explain part whose input carries a non-empty string `nodeId`.
private func isTaggedQuizPart(_ part: ViewPart) -> Bool {
	guard part.type == "tool-quiz" || part.type == "tool-explain" else { return false }
	guard let id = part.input?["nodeId"]?.stringValue else { return false }
	return !id.isEmpty
}

/// One view message's advance of the phase (pure fold step).
private func advance(_ phase: Phase3, _ parts: [ViewPart]) -> Phase3 {
	var phase = phase
	for part in parts {
		if phase == .probe && part.type == "tool-probe_done" && part.state == .outputAvailable { phase = .plan }
		if phase == .plan && isTaggedQuizPart(part) { phase = .teach }
	}
	return phase
}

/// The phase at EVERY view message index, in one forward fold.
public func viewPhaseTimeline(_ messages: [ViewMessage]) -> [Phase3] {
	var out: [Phase3] = []
	out.reserveCapacity(messages.count)
	var phase = Phase3.probe
	for m in messages {
		phase = advance(phase, m.parts)
		out.append(phase)
	}
	return out
}

/// WHERE inside the flipping message teaching begins: -1 when the first
/// tagged quiz/explain call sits in the message's FIRST step (the divider
/// belongs before the whole message), else the index of the step-start part
/// governing the call (the divider replaces that boundary's hairline).
public func viewTeachStepIndex(_ parts: [ViewPart]) -> Int {
	var stepStarts = 0
	var latest = -1
	for (i, part) in parts.enumerated() {
		if part.kind == .stepStart {
			stepStarts += 1
			latest = i
			continue
		}
		if isTaggedQuizPart(part) { return stepStarts <= 1 ? -1 : latest }
	}
	return -1
}

/// The latest plan tree in the transcript (the latest `tool-plan_*` output).
public func latestTree(_ messages: [ViewMessage]) -> PlanTree? {
	for m in messages.reversed() {
		for part in m.parts.reversed() {
			guard part.type.hasPrefix("tool-plan_"), part.state == .outputAvailable else { continue }
			guard let tree = part.output?["tree"], tree["nodes"]?.arrayValue != nil else { continue }
			if let decoded = try? JSONCodec.decode(PlanTree.self, from: tree) { return decoded }
		}
	}
	return nil
}
