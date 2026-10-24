import Foundation
import Testing
@testable import LHCore

// Port of tests/plan-tree.test.ts "parseMermaidPlan (the constrained mermaid subset)".

private func n(_ id: String, _ title: String) -> PlanNode { PlanNode(id: id, title: title) }
private func e(_ a: String, _ b: String) -> PlanEdge { PlanEdge(from: a, to: b) }

@Suite struct MermaidPlanTests {
	@Test func headersCommentsAndBlankLines() {
		for header in ["graph TD", "graph td", "flowchart TB", "Flowchart td"] {
			let r = parseMermaidPlan("\(header)\n%% a comment\n\n  a[Alpha]\n")
			#expect(r.ok, "\(header)")
			#expect(r.plan?.nodes == [n("a", "Alpha")])
		}
	}
	@Test func bareIdsBracketAndParenLabels() {
		#expect(parseMermaidPlan("graph TD\n  bare\n  bracket[Bracket title]\n  paren(\"Paren title\")\n").plan?.nodes
			== [n("bare", "bare"), n("bracket", "Bracket title"), n("paren", "Paren title")])
	}
	@Test func edgesRegisterEndpointsAndDedupe() {
		let r = parseMermaidPlan("graph TD\n  a --> b[Bee]\n  a --> b[Bee]\n")
		#expect(r.plan?.nodes == [n("a", "a"), n("b", "Bee")])
		#expect(r.plan?.edges == [e("a", "b")])
	}
	@Test func labelsOnBothEndpointsAndForwardReferences() {
		let r = parseMermaidPlan("graph TD\n  downstream[Later thing] --> upstream[Earlier thing]\n")
		#expect(r.plan?.edges == [e("downstream", "upstream")])
		#expect(r.plan?.nodes == [n("downstream", "Later thing"), n("upstream", "Earlier thing")])
	}
	@Test func rejections() {
		#expect(!parseMermaidPlan("graph TD\n  Foo Bar[x]\n").ok)
		#expect(parseMermaidPlan("graph TD\n  Foo Bar[x]\n").problems[0].contains(/line 2.*slug/))
		#expect(parseMermaidPlan("graph TD\n  mps.translation[x]\n").problems[0].contains("node id `mps.translation` must be a lowercase slug"))
		#expect(parseMermaidPlan("graph TD\n  MPS[x]\n").problems[0].contains("node id `MPS` must be a lowercase slug"))
		#expect(parseMermaidPlan("graph TD\n  a[Alpha] --> mps.translation[Beta]\n").problems[0].contains("node id `mps.translation` must be a lowercase slug"))
		#expect(!parseMermaidPlan("graph TD\n  a --> a\n").ok)
		#expect(!parseMermaidPlan("graph TD\n  subgraph cluster\n").ok)
		#expect(!parseMermaidPlan("digraph G\n  a\n").ok)
		#expect(!parseMermaidPlan("%% only a comment\n").ok)
	}
	@Test func freeFormPass() {
		let us = parseMermaidPlan("graph TD\n  mps_translation[Ribosomes build protein] --> net_balance[Net balance]\n")
		#expect(us.plan?.nodes == [n("mps_translation", "Ribosomes build protein"), n("net_balance", "Net balance")])
		let quoted = parseMermaidPlan("graph TD\n  mps_translation[\"MPS = ribosomes building protein\"] --> per_meal[\"Per-meal dose: ~20-40 g saturates, excess oxidized\"]\n")
		#expect(quoted.plan?.nodes == [n("mps_translation", "MPS = ribosomes building protein"), n("per_meal", "Per-meal dose: ~20-40 g saturates, excess oxidized")])
		#expect(parseMermaidPlan("graph TD\n  a[Alpha] --> b[Bee] --> c[See]\n").plan?.edges == [e("a", "b"), e("b", "c")])
		for arrow in ["==>", "-.->"] { #expect(parseMermaidPlan("graph TD\n  a \(arrow) b\n").plan?.edges == [e("a", "b")]) }
		for header in ["graph LR", "flowchart RL", "graph BT"] { #expect(parseMermaidPlan("\(header)\n  a --> b\n").ok) }
	}
	@Test func theFirstLabelWins() {
		#expect(parseMermaidPlan("graph TD\n  a[First label]\n  a[Second label]\n").plan?.nodes == [n("a", "First label")])
	}
}
