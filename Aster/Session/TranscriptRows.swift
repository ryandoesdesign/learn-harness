import Foundation
import LHCore
import LHMarkdown

/// One transcript row — the port of chat.tsx's message/part dispatch
/// (lines ~1316–1578), flattened so the LazyVStack, scrolling and Find all
/// work on the same list. Assistant prose is split one row per markdown
/// block (fine-grained lazy layout and scroll targets).
struct TranscriptRow: Identifiable {
	enum Kind {
		/// "YOU" band: plain learner text (no markdown, no LaTeX).
		case userBand(String)
		/// A sub-agent delivery or abort (steer marker).
		case steer(ViewMessage)
		case phaseDivider(Phase3)
		case graphContext(JSONValue)
		case compactionMoment
		case compactionCut(tokensBefore: Int)
		case practiceThinking(String)
		case practiceNext
		/// One block of assistant prose; `anchor` marks the native message's
		/// first prose block (graph links scroll to it).
		case textBlock(MDBlock, anchor: String?)
		case reasoning(String, streaming: Bool)
		/// A tool call being written (input-streaming): spinner + activity label.
		case liveTool(ViewPart)
		case separator
		case planBlock(PlanBlockData)
		case answered(QuestionAnswerData, input: JSONValue?)
		/// An open question, shown where it was asked (the inline card).
		case pendingQuestion(tool: String, toolCallId: String, input: JSONValue)
		case tool(ViewPart)
		case retrying
		case refusal(explanation: String?)
	}

	var id: String
	var kind: Kind
}

/// Tools whose answered result renders as an AnsweredCard.
let ANSWERED_TOOLS: Set<String> = ["quiz", "probe", "ask_user_question", "explain", "recall"]
/// The artifact registry (components/artifacts/index.ts): tools with a card.
let DISPATCH_TOOLS: Set<String> = ["research", "pdf", "demo", "visual"]
let TOOL_CALL_TOOLS: Set<String> = ["read", "ls", "find", "grep", "list_sessions", "list_propositions"]
let CARD_TOOLS: Set<String> = DISPATCH_TOOLS.union(TOOL_CALL_TOOLS).union(["probe_done", "problem", "conclude"])

/// The rows for a record. Pure over (native record, view projection).
@MainActor
func transcriptRows(native: [Message], view: [ViewMessage], streaming: Bool = false) -> [TranscriptRow] {
	let phases = viewPhaseTimeline(view)
	let sourceTextParts = firstSourceTextParts(view)
	let refusals = refusalsByGroup(native: native, view: view)
	let open = Dictionary(danglingQuestionsOf(native).map { ($0.toolCallId, $0) }, uniquingKeysWith: { a, _ in a })
	var rows: [TranscriptRow] = []

	for (mi, m) in view.enumerated() {
		let key = m.id.isEmpty ? "m-\(mi)" : m.id
		if m.role == .user {
			if m.metadata?["subagentResult"] != nil {
				rows.append(TranscriptRow(id: key, kind: .steer(m)))
			} else if m.parts.contains(where: { $0.type == "data-probe-handoff" }) {
				rows.append(TranscriptRow(id: key, kind: .phaseDivider(.plan)))
			} else if !m.parts.isEmpty, m.parts.allSatisfy({ $0.type.hasPrefix("data-") }) {
				for (pi, part) in m.parts.enumerated() {
					let id = "\(key)/\(pi)"
					switch part.type {
					case "data-graph-context": rows.append(TranscriptRow(id: id, kind: .graphContext(part.data ?? .null)))
					case "data-compaction": rows.append(TranscriptRow(id: id, kind: .compactionMoment))
					case "data-compaction-cut":
						let tokens = part.data?["details"]?["tokensBefore"]?.intValue ?? 0
						rows.append(TranscriptRow(id: id, kind: .compactionCut(tokensBefore: tokens)))
					case "data-practice-thinking":
						rows.append(TranscriptRow(id: id, kind: .practiceThinking(part.data?["text"]?.stringValue ?? "")))
					case "data-practice-next": rows.append(TranscriptRow(id: id, kind: .practiceNext))
					default: break
					}
				}
			} else {
				let text = m.parts.filter { $0.kind == .text }.compactMap(\.text).joined(separator: "\n")
				rows.append(TranscriptRow(id: key, kind: .userBand(text)))
			}
			if let refusal = refusals[mi] { rows.append(TranscriptRow(id: "refusal-\(key)", kind: .refusal(explanation: refusal))) }
			continue
		}

		// The inferred teach seam: one divider where the fold flips to teach —
		// before the whole message, or at the governing step boundary.
		let flips = mi > 0 && phases[mi] == .teach && phases[mi - 1] != .teach
		let teachStep = flips ? viewTeachStepIndex(m.parts) : -2
		if teachStep == -1 { rows.append(TranscriptRow(id: "teach-\(key)", kind: .phaseDivider(.teach))) }

		for (pi, part) in m.parts.enumerated() {
			let id = "\(key)/\(pi)"
			if part.state == .outputError, part.toolName != nil, part.errorText != "Operation aborted" {
				rows.append(TranscriptRow(id: id, kind: .retrying))
				continue
			}
			switch part.kind {
			case .text:
				let blocks = MarkdownCache.blocks(part.text ?? "")
				let sourceId = textPartMessageId(part.id)
				let anchor = sourceId.flatMap { sourceTextParts[$0] == part.id ? messageAnchorId($0) : nil }
				for (bi, block) in blocks.enumerated() {
					rows.append(TranscriptRow(id: "\(id)/b\(bi)", kind: .textBlock(block, anchor: bi == 0 ? anchor : nil)))
				}
			case .reasoning:
				let isLast = mi == view.count - 1 && pi == m.parts.count - 1
				rows.append(TranscriptRow(id: id, kind: .reasoning(part.text ?? "", streaming: streaming && isLast)))
			case .stepStart:
				if pi == teachStep {
					rows.append(TranscriptRow(id: id, kind: .phaseDivider(.teach)))
				} else if pi > 0 {
					rows.append(TranscriptRow(id: id, kind: .separator))
				}
			case .data("plan-block"):
				if let data = part.data, let block = try? JSONCodec.decode(PlanBlockData.self, from: data) {
					rows.append(TranscriptRow(id: id, kind: .planBlock(block)))
				}
			case .tool(let name) where ANSWERED_TOOLS.contains(name):
				// The question's `message` is the reply he reads before it: prose, as any reply.
				if let message = (part.input?["message"] ?? part.rawInput?["message"])?.stringValue, !message.jsTrimmed.isEmpty {
					// The display repairs the question's own fields get (a double-escaped `\n`, math).
					for (bi, block) in MarkdownCache.blocks(repairMathForDisplay(restoreLiteralNewlines(message))).enumerated() {
						rows.append(TranscriptRow(id: "\(id)/m/b\(bi)", kind: .textBlock(block, anchor: nil)))
					}
				}
				// Answered questions are records; open ones are cards where they were asked.
				if part.state == .outputAvailable, let output = part.output, let answer = QuestionAnswerData(json: output) {
					rows.append(TranscriptRow(id: id, kind: .answered(answer, input: part.input)))
				} else if let callId = part.toolCallId, let q = open[callId] {
					rows.append(TranscriptRow(id: id, kind: .pendingQuestion(tool: q.tool, toolCallId: q.toolCallId, input: q.input)))
				}
			case .tool where part.state == .inputStreaming:
				rows.append(TranscriptRow(id: id, kind: .liveTool(part)))
			case .tool(let name) where CARD_TOOLS.contains(name):
				// Dispatch boxes need the ack.
				if DISPATCH_TOOLS.contains(name), part.state != .outputAvailable { continue }
				rows.append(TranscriptRow(id: id, kind: .tool(part)))
			default:
				break
			}
		}
		if let refusal = refusals[mi] {
			rows.append(TranscriptRow(id: "refusal-\(key)", kind: .refusal(explanation: refusal)))
		}
	}
	return rows
}

/// View-message index → the refusal explanation (nil = none given) for
/// each refused native assistant message: it renders after the last view
/// message at or before it (a contentless refusal projects no group).
private func refusalsByGroup(native: [Message], view: [ViewMessage]) -> [Int: String?] {
	let nativeIndex = Dictionary(native.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
	let groups: [(view: Int, native: Int)] = view.enumerated().compactMap { i, m in
		guard let n = nativeIndex[m.id] else { return nil }
		return (i, n)
	}
	var out: [Int: String?] = [:]
	for (r, m) in native.enumerated() {
		guard let a = m.assistant, a.stopReason == "refusal" else { continue }
		guard let group = groups.last(where: { $0.native <= r }) else { continue }
		let explanation = a.stopDetails?["explanation"]?.stringValue
		out[group.view] = explanation.flatMap { $0.isEmpty ? nil : $0 }
	}
	return out
}
