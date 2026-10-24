import CryptoKit
import Foundation

// The pure halves of src/agent/subagents/extraction.ts (docs/native-macos-m7.md):
// what the extractor reads (prose view, digest, notes chunks), and the submit
// seam's fills and validators. Strings are TS-identical.

/// extraction.ts proseView: teacher prose only, one "TEACHER [id] text" line
/// per text block (the lines coverage fingerprints), under the title.
public func proseView(_ messages: [Message], title: String?) -> String {
	let lines = messages.flatMap { messageViewLines($0, mid: $0.id) }
	let head = (title ?? "").isEmpty ? "" : "# \(title!)\n\n"
	return head + lines.joined(separator: "\n\n")
}

/// The batch's anchorable ids: messages that contribute view lines.
public func batchAnchorIds(_ messages: [Message]) -> Set<String> {
	Set(messages.filter { !messageViewLines($0, mid: $0.id).isEmpty }.map(\.id))
}

/// extraction.ts sourceDigest: what this source already put in the graph ("" = nothing).
public func sourceDigest(_ graph: DerivedGraph, sourceId: String) -> String {
	let nameOf = Dictionary(graph.nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
	let ours = graph.nodes.filter { $0.provenance.contains { $0.chatId == sourceId } }
	let ourChains = graph.chains.filter { $0.provenance.contains { $0.chatId == sourceId } }
	if ours.isEmpty, ourChains.isEmpty { return "" }
	var lines = ["THE GRAPH SO FAR — everything already extracted from this source (reference these ids verbatim):"]
	for n in ours { lines.append("  \(n.id) | \(n.name) | \(n.statement.replacing(/\s+/, with: " "))") }
	if !ourChains.isEmpty {
		lines.append("DERIVATIONS ALREADY RECORDED (build on these; do not re-derive them):")
		for c in ourChains {
			let names = c.premises.map { nameOf[$0] ?? $0 }.joined(separator: " ∧ ")
			lines.append("  [\(c.premises.joined(separator: " + ")) ⇒ \(c.conclusion)]  \(names) ⇒ \(nameOf[c.conclusion] ?? c.conclusion)")
		}
	}
	return lines.joined(separator: "\n")
}

/// The extractor's prompt: the digest (when any), then the view.
public func extractorPrompt(digest: String, view: String) -> String {
	digest.isEmpty ? view : "\(digest)\n\n\(view)"
}

/// extraction.ts chunkNotes: greedy by line under ~4 chars/token; a line is never split.
public func chunkNotes(_ text: String, budget: Int) -> [String] {
	if text.jsTrimmed.isEmpty { return [] }
	var out: [String] = []
	var current = ""
	for line in text.components(separatedBy: "\n") {
		let candidate = current.isEmpty ? line : current + "\n" + line
		if !current.isEmpty, Int((Double(candidate.jsLength) / 4).rounded(.up)) > budget {
			out.append(current)
			current = line
		} else {
			current = candidate
		}
	}
	if !current.jsTrimmed.isEmpty { out.append(current) }
	return out
}

/// extraction.ts notesView: the source header, then the chunk.
public func notesView(filePath: String, text: String, part: (i: Int, n: Int)?) -> String {
	let suffix = part.map { $0.n > 1 ? " (part \($0.i)/\($0.n))" : "" } ?? ""
	return "SOURCE (the author's personal notes): \(filePath)\(suffix)\n\n\(text)"
}

/// The auditor's prompt: the findings' propositions (no anchors, no chains)
/// and the graph's size.
public func auditorPrompt(_ findings: SessionFindings, graphNodeCount: Int) -> String {
	let props: [JSONValue] = findings.propositions.map {
		.object(JSONObject(pairs: [("id", .string($0.id)), ("name", .string($0.name)), ("statement", .string($0.statement)),
			("aliases", .array($0.aliases.map(JSONValue.string)))]))
	}
	let json = JSONValue.object(JSONObject(pairs: [("propositions", .array(props))])).serialized(indent: 2)
	return "Proposed findings from the extractor (the source itself is not available to you — the extractor is fully trusted; the propositions only — the reasoning chains are the merger's business, owner 2026-09-30):\n\n"
		+ "\(json)\n\n"
		+ "The current knowledge graph has \(graphNodeCount) node(s). Explore it with your tools and link what links."
}

// MARK: - The submit seam

/// fillFindings / fillNotesFindings: aliases default to []; the notes door
/// strips any messageId (notes provenance stays file-level). nil = the
/// payload is not the findings shape (the schema already said why).
public func decodeFindings(_ v: JSONValue, notes: Bool) -> SessionFindings? {
	guard let props = v["propositions"]?.arrayValue, let chains = v["chains"]?.arrayValue else { return nil }
	var out = SessionFindings(propositions: [], chains: [])
	for p in props {
		guard let id = p["id"]?.stringValue, let name = p["name"]?.stringValue, let statement = p["statement"]?.stringValue else { return nil }
		let aliases = (p["aliases"]?.arrayValue ?? []).compactMap(\.stringValue)
		out.propositions.append(ExtractedProposition(id: id, name: name, statement: statement, aliases: aliases,
			messageId: notes ? nil : p["messageId"]?.stringValue))
	}
	for c in chains {
		guard let premises = c["premises"]?.arrayValue?.compactMap(\.stringValue), let conclusion = c["conclusion"]?.stringValue else { return nil }
		out.chains.append(ExtractedChain(premises: premises, conclusion: conclusion))
	}
	return out
}

public func decodeVerdicts(_ v: JSONValue) -> AuditVerdicts? {
	guard let links = v["links"]?.arrayValue else { return nil }
	var out: [IdentityLink] = []
	for l in links {
		guard let id = l["id"]?.stringValue, let to = l["linkTo"]?.stringValue else { return nil }
		out.append(IdentityLink(id: id, linkTo: to))
	}
	return AuditVerdicts(links: out)
}

/// extraction.ts validateFindingsChains: every endpoint resolves (a local id
/// or an existing graph id), and no conclusion is its own premise.
public func validateFindingsChains(_ f: SessionFindings, existingIds: Set<String>) -> String? {
	let ids = Set(f.propositions.map(\.id))
	for chain in f.chains {
		if chain.premises.isEmpty {
			return "chains: premises must name at least one proposition — a proposition with no argument stays in the propositions list alone."
		}
		if let unknown = (chain.premises + [chain.conclusion]).first(where: { !ids.contains($0) && !existingIds.contains($0) }) {
			return "chains: \"\(unknown)\" is neither a submitted proposition id nor an existing idea id from THE GRAPH SO FAR — every premise and conclusion must resolve."
		}
		if chain.premises.contains(chain.conclusion) { return "chains: a conclusion cannot be its own premise." }
	}
	return nil
}

/// extraction.ts validateSessionAnchors: every proposition names a passage of THIS batch.
public func validateSessionAnchors(_ f: SessionFindings, batchIds: Set<String>) -> String? {
	for p in f.propositions {
		let mid = p.messageId ?? ""
		if mid.jsTrimmed.isEmpty {
			return "propositions: \"\(p.id)\" is missing its messageId — copy the message id from the brackets of the passage (TEACHER [id]) that most directly states or explains it."
		}
		if !batchIds.contains(mid) {
			return "propositions: \"\(p.id)\" names messageId \"\(mid)\", which is not a passage of THIS stretch — copy the id from the brackets of one of this stretch's own TEACHER [id] passages."
		}
	}
	return nil
}

/// The notes source id (your answer: the full path): "src_" + sha256(path)[0..<12].
public func notesSourceId(path: String) -> String {
	"src_" + String(GraphJS.hex(SHA256.hash(data: Data(path.utf8))).prefix(12))
}
