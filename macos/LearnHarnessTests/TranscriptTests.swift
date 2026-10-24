import AppKit
import Foundation
import LHCore
import LHMarkdown
import LHResources
import LHStore
import SwiftUI
import Testing
@testable import LearnHarness

// M4 acceptance in the host: the Render Gallery and both golden chats build
// their transcript rows, every row kind is covered, and every row renders
// offscreen without trapping.

@MainActor
@Suite struct TranscriptTests {
	private func session(for record: ChatRecord) throws -> SessionModel {
		let dir = FileManager.default.temporaryDirectory.appending(path: "lhtx-\(UUID().uuidString)", directoryHint: .isDirectory)
		let db = try AppDatabase.open(directory: dir)
		try ChatRepository(db).insert(record, origin: .native)
		let catalog = try ModelCatalog(data: LHResources.modelsJSON)
		let s = SessionModel(chatId: record.id, database: db, dataDirectory: dir, catalog: catalog)
		s.load()
		return s
	}

	private func kindName(_ k: TranscriptRow.Kind) -> String {
		String(describing: k).components(separatedBy: "(").first ?? ""
	}

	@Test func theGalleryCarriesEveryMarkerKind() {
		let kinds = Set(RenderGallery.record().messages.compactMap { $0.marker?.kind })
		#expect(kinds == Set(MarkerKind.allCases))
	}

	@Test func theGalleryCoversEveryRowKind() throws {
		let s = try session(for: RenderGallery.record())
		let covered = Set(s.rows.map { kindName($0.kind) })
		let all: Set = ["userBand", "steer", "phaseDivider", "graphContext", "compactionMoment", "compactionCut", "practiceThinking",
			"practiceNext", "textBlock", "reasoning", "separator", "planBlock", "answered", "tool", "retrying", "refusal"]
		#expect(all.subtracting(covered).isEmpty, "missing: \(all.subtracting(covered).sorted())")
		// Both phase seams, every tool card, the refusal explanation.
		let dividers = s.rows.compactMap { if case .phaseDivider(let p) = $0.kind { return p }; return nil }
		#expect(dividers == [.plan, .teach])
		let tools = Set(s.rows.compactMap { if case .tool(let p) = $0.kind { return p.toolName }; return nil })
		#expect(tools.isSuperset(of: ["probe_done", "ls", "research", "pdf", "visual", "demo", "problem", "conclude"]))
		#expect(s.rows.contains { if case .refusal(let e) = $0.kind { return e?.contains("outside") == true }; return false })
		#expect(s.plan?.nodes.count == 4)
		#expect(s.phase == .teach)
	}

	@Test func theGalleryMarkdownCoversEveryBlockKind() throws {
		let s = try session(for: RenderGallery.record())
		let blocks = s.rows.compactMap { if case .textBlock(let b, _) = $0.kind { return String(describing: b).components(separatedBy: "(").first }; return nil }
		#expect(Set(blocks).isSuperset(of: ["paragraph", "heading", "list", "quote", "callout", "code", "mermaid", "displayMath", "table", "thematicBreak"]))
	}

	/// The reported gallery bug: no TeX leaks into prose, and every math
	/// span typesets (the clean-span fix in transformMathDelimiters).
	@Test func theGalleryMathAllTypesets() throws {
		let s = try session(for: RenderGallery.record())
		var maths: [String] = []
		var prose = ""
		func walk(_ runs: [MDInline]) {
			for r in runs {
				switch r {
				case .math(let t): maths.append(t)
				case .text(let t): prose += t
				case .emphasis(let c), .strong(let c), .strikethrough(let c), .link(_, let c): walk(c)
				default: break
				}
			}
		}
		for row in s.rows {
			guard case .textBlock(let b, _) = row.kind else { continue }
			switch b {
			case .paragraph(let r), .heading(_, let r): walk(r)
			case .displayMath(let t, _): maths.append(t)
			case .list(_, _, let items): for i in items { for case .paragraph(let r) in i.blocks { walk(r) } }
			default: break
			}
		}
		#expect(!prose.contains("\\"), "TeX leaked into prose: \(prose)")
		#expect(maths.contains { $0.contains("aligned") })
		#expect(maths.contains { $0.contains("nabla") })
		// Every span typesets except the deliberate raw-TeX example.
		let failing = maths.filter { mathParseError($0) != nil }
		#expect(failing == [#"\notacommand{x}"#], "\(failing)")
	}

	@Test func findSearchesVisibleUnitsAndSkipsCollapsedOnes() throws {
		let s = try session(for: RenderGallery.record())
		s.find.open()
		s.find.query = "learner knows python"
		#expect(s.find.matches.isEmpty, "the reasoning row is collapsed")
		let reasoning = s.rows.first { if case .reasoning = $0.kind { return true }; return false }!
		s.setOpen(reasoning.id, true)
		#expect(s.find.matches.count == 1)
		s.find.query = "join"
		#expect(s.find.matches.count > 3)
		let first = s.find.active
		s.find.step(-1)
		#expect(s.find.active == s.find.matches.count - 1 && first == 0)
	}

	@Test func anchorsResolveToTheFirstProseBlock() throws {
		let s = try session(for: RenderGallery.record())
		s.scrollTo(messageId: "a6")
		let row = s.anchorRequest.flatMap(s.rowId(forAnchor:))
		#expect(row != nil)
	}

	@Test(arguments: ["chat_mv27rrra_feff23b6", "chat_mv293wv5_10656952"])
	func goldenChatsBuildAndRender(_ name: String) throws {
		let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "json", subdirectory: "chats"))
		let record = try #require(ChatRecord(legacyJSON: try JSONValue.parse(Data(contentsOf: url))))
		let s = try session(for: record)
		#expect(!s.rows.isEmpty)
		try renderAll(s)
	}

	@Test func everyGalleryRowRenders() throws {
		try renderAll(try session(for: RenderGallery.record()))
	}

	private func renderAll(_ s: SessionModel) throws {
		for row in s.rows {
			let view = RowView(row: row)
				.environment(s)
				.environment(s.find)
				.environment(s.overlays)
				.frame(width: 720)
			let renderer = ImageRenderer(content: view)
			#expect(renderer.nsImage != nil, "row \(row.id) did not render")
		}
	}

	@Test func sidebarFilterAndRank() {
		func summary(_ id: String, _ title: String, _ kind: ChatKind) -> ChatSummary {
			ChatSummary(id: id, title: title, createdAt: "", updatedAt: "2026-10-24T00:00:00.000Z", kind: kind, messageCount: 0, phase: .probe, pendingQuestion: false, pendingProblem: false)
		}
		let list = [summary("1", "Relational joins", .teach), summary("2", "Join practice", .practice), summary("3", "Calculus", .teach)]
		#expect(filteredSessions(list, query: "", filter: .practice).map(\.id) == ["2"])
		#expect(filteredSessions(list, query: "", filter: .all).map(\.id) == ["1", "2", "3"])
		#expect(filteredSessions(list, query: "join", filter: .all).map(\.id) == ["2", "1"])
		#expect(filteredSessions(list, query: "zzz", filter: .all).isEmpty)
	}

	@Test func sessionMetaStates() {
		var s = ChatSummary(id: "1", title: "t", createdAt: "", updatedAt: "2026-10-24T00:00:00.000Z", kind: .practice, messageCount: 0, phase: .probe, pendingQuestion: true, pendingProblem: true)
		let now = ISO8601DateFormatter().date(from: "2026-10-24T00:05:00Z")!
		#expect(sessionMeta(s, now: now) == "Waiting for input · 5m ago")
		s.pendingQuestion = false
		#expect(sessionMeta(s, now: now) == "Problem waiting · 5m ago")
		s.pendingProblem = false
		#expect(sessionMeta(s, now: now) == "5m ago")
	}
}

private final class BundleToken {}
