import Foundation
import LHCore
import Testing
@testable import LHMarkdown

// Port of tests/render-markdown.test.tsx and tests/render-md-blocks.test.tsx
// to the block model. A KaTeX DOM assertion ("renders katex", "no
// katex-error") becomes "the TeX reaches MDInline.math / displayMath and
// MathJax typesets it". Hover/DOM-geometry cases have no native analogue.

private func parse(_ s: String) -> [MDBlock] { parseMessageMarkdown(s) }

/// Every math TeX in the blocks, inline and display, in order.
private func maths(_ blocks: [MDBlock]) -> [(tex: String, display: Bool)] {
	var out: [(String, Bool)] = []
	func inl(_ runs: [MDInline]) {
		for r in runs {
			switch r {
			case .math(let t): out.append((t, false))
			case .emphasis(let c), .strong(let c), .strikethrough(let c), .link(_, let c): inl(c)
			default: break
			}
		}
	}
	func blk(_ bs: [MDBlock]) {
		for b in bs {
			switch b {
			case .paragraph(let r), .heading(_, let r): inl(r)
			case .list(_, _, let items): items.forEach { blk($0.blocks) }
			case .quote(let c), .callout(_, let c): blk(c)
			case .displayMath(let t, _): out.append((t, true))
			case .table(let h, let rows, _): h.forEach(inl); rows.forEach { $0.forEach(inl) }
			default: break
			}
		}
	}
	blk(blocks)
	return out
}

private func paragraphs(_ blocks: [MDBlock]) -> [String] {
	blocks.compactMap { if case .paragraph(let r) = $0 { return r.plainText }; return nil }
}

@Suite struct DollarMathAndLegacyTests {
	@Test func parensAreInline() {
		let m = maths(parse("The map \\(f(x) = x^2\\) is smooth."))
		#expect(m.count == 1 && !m[0].display)
		#expect(mathParseError(m[0].tex) == nil)
	}
	@Test func bracketsOnOwnLinesAreDisplay() {
		let m = maths(parse("Intro:\n\n\\[\n\\int_0^1 x^2\\,dx = \\tfrac{1}{3}\n\\]\n\nOutro."))
		#expect(m.count == 1 && m[0].display)
		#expect(mathParseError(m[0].tex) == nil)
	}
	@Test func midParagraphBracketsHoistToDisplayWithoutLeakingDollars() {
		let blocks = parse("before \\[x^2\\] after")
		let m = maths(blocks)
		#expect(m.count == 1 && m[0].display && m[0].tex == "x^2")
		#expect(!paragraphs(blocks).joined().contains("$$"))
		#expect(paragraphs(blocks) == ["before", "after"])
	}
	@Test func displayMathInsideListItemsKeepsTheList() {
		let blocks = parse("- item one\n  \\[x^2\\]\n- item two")
		guard case .list(_, _, let items)? = blocks.first else { Issue.record("no list"); return }
		#expect(items.count == 2)
		#expect(maths(blocks).count == 1)
		#expect(paragraphs(items[1].blocks) == ["item two"])
	}
	@Test func escapedCurrencyStaysLiteral() {
		let blocks = parse("It costs \\$5 and \\$10 more.")
		#expect(maths(blocks).isEmpty)
		#expect(paragraphs(blocks) == ["It costs $5 and $10 more."])
	}
	@Test func singleDollarIsInline() {
		let m = maths(parse("The map $f(x) = x^2$ is smooth."))
		#expect(m.count == 1 && !m[0].display && m[0].tex == "f(x) = x^2")
	}
	@Test func dollarCommandsAndFencedDisplay() {
		let m = maths(parse("The symbol $\\Omega$ appears here.\n\n$$\nS = k_B \\ln \\Omega\n$$"))
		#expect(m.map(\.display) == [false, true])
		#expect(m.allSatisfy { mathParseError($0.tex) == nil })
	}
	@Test func codeKeepsDollarExamplesLiteral() {
		let blocks = parse("Use `$x$` here.\n\n```text\n$$\ny = x^2\n$$\n```")
		#expect(maths(blocks).isEmpty)
		guard case .paragraph(let runs) = blocks[0] else { Issue.record(); return }
		#expect(runs.contains(.code("$x$")))
		#expect(blocks[1] == .code(language: "text", source: "$$\ny = x^2\n$$", startLine: nil, lineNumbers: true))
	}
	@Test func parensInsideACodeFenceStayLiteral() {
		let blocks = parse("```\n\\(x^2\\) stays literal\n```")
		#expect(blocks == [.code(language: nil, source: "\\(x^2\\) stays literal", startLine: nil, lineNumbers: true)])
	}
	@Test func unbalancedBracketMidStreamIsUntouched() {
		let blocks = parse("partial \\[ mid-stream")
		#expect(maths(blocks).isEmpty)
		#expect(!paragraphs(blocks).joined().contains("$$"))
	}
	@Test func mathInsideHeadings() {
		let blocks = parse("## The map \\(f(x)\\)")
		guard case .heading(2, let runs) = blocks[0] else { Issue.record("no h2"); return }
		#expect(runs.contains(.math("f(x)")))
	}
}

@Suite struct LineBreakTests {
	@Test func singleNewlineIsALineBreak() {
		#expect(parse("line one\nline two") == [.paragraph([.text("line one"), .lineBreak, .text("line two")])])
	}
	@Test func codeBlocksKeepTheirLines() {
		#expect(parse("```js\nline one\nline two\n```") == [.code(language: "js", source: "line one\nline two", startLine: nil, lineNumbers: true)])
	}
	@Test func listsStayLists() {
		guard case .list(false, _, let items) = parse("- alpha\n- beta")[0] else { Issue.record(); return }
		#expect(items.map { paragraphs($0.blocks) } == [["alpha"], ["beta"]])
	}
	@Test func gfmTables() {
		guard case .table(let header, let rows, _) = parse("| a | b |\n|---|---|\n| 1 | 2 |")[0] else { Issue.record(); return }
		#expect(header.map(\.plainText) == ["a", "b"])
		#expect(rows.map { $0.map(\.plainText) } == [["1", "2"]])
	}
}

@Suite struct MermaidBlockTests {
	@Test func mermaidFenceIsADiagramNotCode() {
		#expect(parse("```mermaid\ngraph TD\nA --> B\n```") == [.mermaid(source: "graph TD\nA --> B", closed: true)])
	}
	@Test func ordinaryFencesStayCode() {
		#expect(parse("```js\nconst x = 1;\n```") == [.code(language: "js", source: "const x = 1;", startLine: nil, lineNumbers: true)])
	}
	@Test func anUnclosedMermaidFenceIsOpen() {
		#expect(parse("```mermaid\ngraph TD\nA --> B") == [.mermaid(source: "graph TD\nA --> B", closed: false)])
	}
}

@Suite struct EmphasisTests {
	@Test func boldIsStrong() {
		#expect(parse("plain **bold** plain") == [.paragraph([.text("plain "), .strong([.text("bold")]), .text(" plain")])])
	}
	@Test func italicIsEmphasis() {
		#expect(parse("plain *emph* plain") == [.paragraph([.text("plain "), .emphasis([.text("emph")]), .text(" plain")])])
	}
}

@Suite struct EscapedDollarRenderingTests {
	@Test func oneCleanSpanWithAVisibleDollar() {
		let m = maths(parse("It costs $x = \\$5$ at market."))
		#expect(m.count == 1)
		#expect(m[0].tex.contains("\\text{\\textdollar}"))
		#expect(mathParseError(m[0].tex) == nil)
	}
	@Test func theSessionCascadeRendersEverySpan() {
		let blocks = parse("Line A: $x = \\$5$.\n\nLine B: $y = 2$.\n\nWhat is $2 + 2$?")
		#expect(maths(blocks).count == 3)
		#expect(maths(blocks).allSatisfy { mathParseError($0.tex) == nil })
		#expect(paragraphs(blocks)[1].hasPrefix("Line B:"))
	}
	@Test func textModeDollar() {
		let m = maths(parse("Price: $\\text{\\$}12$ today."))
		#expect(m.count == 1)
		#expect(mathParseError(m[0].tex) == nil)
	}
	@Test func legacyParensWithAnEscapedDollar() {
		let m = maths(parse("Old form \\(x = \\$5\\) renders."))
		#expect(m.count == 1)
		#expect(mathParseError(m[0].tex) == nil)
	}
	@Test func codeSpansKeepTheEscapedDollarLiteral() {
		let blocks = parse("Type `$x = \\$5$` literally.")
		#expect(maths(blocks).isEmpty)
		guard case .paragraph(let runs) = blocks[0] else { Issue.record(); return }
		#expect(runs.contains(.code("$x = \\$5$")))
	}
}

@Suite struct OverescapedHealRenderingTests {
	static let gdQuestion =
		"Let $f : \\mathbb{R}^n \\to \\mathbb{R}$ be differentiable at $x$, with $\\nabla f(x) \\neq 0$. The directional derivative along a unit direction $u$ is $D_u f(x) = \\nabla f(x)^\\top u$. Among all unit directions $\\|u\\|_2 = 1$, which one makes $D_u f(x) **most negative** (steepest descent)?"

	@Test func theDoubledFormNeverReachesTheCommands() {
		let raw = Self.gdQuestion.replacingOccurrences(of: "\\", with: "\\\\")
		#expect(maths(parse(raw)).allSatisfy { !$0.tex.contains("\\nabla") || $0.tex.contains("\\\\nabla") })
	}
	@Test func theHealedQuestionParsesCleanly() {
		let healed = healOverescapedCommands(Self.gdQuestion.replacingOccurrences(of: "\\", with: "\\\\"))
		let m = maths(parse(healed))
		#expect(m.contains { $0.tex.contains("\\nabla") })
		#expect(m.contains { $0.tex.contains("\\top") })
		#expect(m.allSatisfy { mathParseError($0.tex) == nil }, "\(m.map(\.tex).filter { mathParseError($0) != nil })")
	}
	@Test func theHealedInferenceRuntimeQuestionParsesCleanly() {
		let ir = "Let $A \\in \\mathbb{R}^{m \\times k}$ and $B \\in \\mathbb{R}^{k \\times n}$, and let $C = AB$ be their matrix product."
		let m = maths(parse(healOverescapedCommands(ir.replacingOccurrences(of: "\\", with: "\\\\"))))
		#expect(m.count == 3)
		#expect(m.allSatisfy { mathParseError($0.tex) == nil })
	}
}

@Suite struct MDBlocksTests {
	@Test func inlineCodeIsAPill() {
		#expect(parse("a `term` b") == [.paragraph([.text("a "), .code("term"), .text(" b")])])
	}
	@Test func fenceMeta() {
		#expect(parse("```py startLine=10\nx\n```") == [.code(language: "py", source: "x", startLine: 10, lineNumbers: true)])
		#expect(parse("```py noLineNumbers\nx\n```") == [.code(language: "py", source: "x", startLine: nil, lineNumbers: false)])
		#expect(parse("```py startLine=0\nx\n```") == [.code(language: "py", source: "x", startLine: nil, lineNumbers: true)])
	}
	@Test func displayMathCopySourceIsTheTeX() {
		let b = parse("$$\n\\int_0^1 x^2\\,dx = \\tfrac{1}{3}\n$$")
		#expect(b == [.displayMath(tex: "\\int_0^1 x^2\\,dx = \\tfrac{1}{3}", closed: true)])
		#expect(codeSource(b[0]) == "\\int_0^1 x^2\\,dx = \\tfrac{1}{3}")
		#expect(mathParseError(codeSource(b[0])!) == nil)
	}
	@Test func anUnclosedDisplayFenceIsOpen() {
		#expect(parse("$$\nx^2") == [.displayMath(tex: "x^2", closed: false)])
	}
	@Test func codeSourceOfAFence() {
		#expect(codeSource(.code(language: "js", source: "const x = 1;", startLine: nil, lineNumbers: true)) == "const x = 1;")
		#expect(codeSource(.thematicBreak) == nil)
	}
}

@Suite struct CalloutTests {
	@Test func importantCalloutBoxesAndTheMarkerNeverLeaks() {
		#expect(parse("> [!IMPORTANT]\n> ALL X is done through Y.") == [.callout(kind: "important", [.paragraph([.text("ALL X is done through Y.")])])])
	}
	@Test func allFiveMarkersBoxIdentically() {
		for kind in ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"] {
			#expect(parse("> [!\(kind)]\n> Load-bearing words.") == [.callout(kind: kind.lowercased(), [.paragraph([.text("Load-bearing words.")])])])
		}
	}
	@Test func aStandaloneMarkerDropsTheEmptyParagraph() {
		#expect(parse("> [!IMPORTANT]\n>\n> The payoff lands here.") == [.callout(kind: "important", [.paragraph([.text("The payoff lands here.")])])])
	}
	@Test func multiParagraphCalloutsKeepTheirStructure() {
		#expect(parse("> [!IMPORTANT]\n> First the truth.\n>\n> Then the payoff.") == [.callout(kind: "important", [
			.paragraph([.text("First the truth.")]), .paragraph([.text("Then the payoff.")]),
		])])
	}
	@Test func plainQuotesStayQuotes() {
		#expect(parse("Before.\n\n> An ordinary quote.\n\nAfter.") == [
			.paragraph([.text("Before.")]), .quote([.paragraph([.text("An ordinary quote.")])]), .paragraph([.text("After.")]),
		])
	}
	@Test func parseAlertMarkerPure() {
		#expect(parseAlertMarker("just text") == nil)
		#expect(parseAlertMarker("[!tip]  ")?.kind == "tip")
		#expect(parseAlertMarker("[!tip] rest") == nil)
		#expect(parseAlertMarker("[!NOTE]\nbody")?.rest == "body")
		#expect(parseAlertMarker("x [!NOTE]") == nil)
	}
}
