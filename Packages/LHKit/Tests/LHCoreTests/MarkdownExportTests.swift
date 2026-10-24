import Foundation
import Testing
@testable import LHCore

// Port of tests/markdown-export.test.ts (the route's pure parts: the
// filename slug and the anchorless document), plus download.ts's slug.

@Suite struct MarkdownExportTests {
	@Test func slugifiedTitleNamesTheFile() {
		#expect(sessionExportSlug("Relational Databases — Joins & Normal Forms") == "relational-databases-joins-normal-forms")
	}
	@Test func anUnsalvageableTitleFallsBackToSession() {
		#expect(sessionExportSlug("日本語") == "session")
	}
	@Test func exportsAnchorlessLearnerAndTeacherBlocks() {
		let messages = [
			newUserMessage("Teach me joins", id: "m1", now: 0),
			Message(id: "m2", timestamp: 0, body: .assistant(AssistantBody(content: [.text("A join combines rows.")], model: "claude-opus-5-5", stopReason: "end_turn"))),
		]
		let body = sessionMarkdown(messages, title: "Relational Databases — Joins & Normal Forms", anchors: false)
		#expect(body.hasPrefix("# Relational Databases"))
		#expect(body.contains("### Learner"))
		#expect(body.contains("### Teacher"))
		#expect(!body.contains("m1"))
	}
	@Test func anEmptySessionExportsTheBareHeader() {
		#expect(sessionMarkdown([], title: "Quiet one", anchors: false) == "# Quiet one")
	}
	@Test func demoSlugFoldsAccentsAndCaps() {
		#expect(slugFilename("Café — Résumé!") == "cafe-resume")
		#expect(slugFilename("!!!") == "demo")
		#expect(slugFilename(String(repeating: "a", count: 80)).count == 64)
	}
}
