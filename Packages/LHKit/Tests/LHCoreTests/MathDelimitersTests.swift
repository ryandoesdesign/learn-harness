import Foundation
import Testing
@testable import LHCore

// Ports of the pure-function assertions in tests/repair-math-display.test.tsx,
// tests/render-markdown.test.tsx and tests/tool-parts.test.ts. JS `\f`/`\x0c`,
// `\v`/`\x0b` and `\b` are written `\u{0C}`, `\u{0B}`, `\u{08}`.

private let tex = #"\nabla f(x) \in \mathbb{R}^{m \times n}"#
private let clean = "$" + tex + "$"
private let doubled = clean.replacing("\\", with: "\\\\")
private let quadrupled = clean.replacing("\\", with: "\\\\\\\\")
/// JSON's form feed consumed the f.
private let debris = "$\u{0C}orall x \\in \\mathbb{R}$"
private let repairedDebris = #"\forall x \in \mathbb{R}"#
private let matrix = "$$\n" + #"\\begin{pmatrix}1 & 2 \\ 3 & 4\\end{pmatrix}"# + "\n$$"
private let repairedMatrix = #"\begin{pmatrix}1 & 2 \\ 3 & 4\end{pmatrix}"#

private let unchanged: [String] = [
	clean,
	#"outside \\nabla"#,
	#"$a \\\nabla b$"#,
	#"$a \\\\\nabla b$"#,
	#"$a \\ 2 \\& 3 \\[6pt] 4$"#,
	"$$\na \\\\\\\\ 2\nb\n$$", // four real row-break slashes survive too.
	"`" + doubled + "`",
	"```tex\n" + doubled + "\n```",
	"`" + debris + "`",
	"```tex\n" + debris + "\n```",
	#"$\\nabla"#,
	"$$A = \\\\begin{pmatrix}\n1 & 2\n\\\\end{pmatrix}$$", // unsupported midline display close.
]

@Suite struct RepairMathForDisplayTests {
	@Test(arguments: unchanged + [doubled, quadrupled, debris, matrix, #"\(\\nabla\)"#, "\\[\n\\\\nabla\n\\]"])
	func matchesTheOldCompositionByteForByte(value: String) {
		#expect(repairMathForDisplay(value) == healOverescapedCommands(restoreMathEscapes(value)))
	}

	@Test func preservesCleanMathOddRunsRowBreaksCodeProseAndRecognitionLimits() {
		for value in unchanged { #expect(repairMathForDisplay(value) == value) }
		#expect(repairMathForDisplay(doubled) == clean)
		#expect(repairMathForDisplay(quadrupled) == clean)
		#expect(repairMathForDisplay(debris) == "$\(repairedDebris)$")
		#expect(repairMathForDisplay(matrix) == "$$\n\(repairedMatrix)\n$$")
	}

	/// repair-math-display "teaching quiz/ask/explain": the parse seam applies
	/// repairMathForDisplay to each string field (restoreMathEscapesDeep).
	@Test func teachingFieldsRepairTheSameBytes() {
		#expect(repairMathForDisplay(doubled) == clean)
		#expect(repairMathForDisplay(debris) == "$\(repairedDebris)$")
	}
}

@Suite struct TransformMathDelimitersTests {
	@Test func convertsInlineToTwoDollarForm() {
		#expect(transformMathDelimiters("a \\(x^2\\) b") == "a $$x^2$$ b")
	}

	@Test func convertsBlockPositionedDisplayInPlace() {
		#expect(transformMathDelimiters("text\n\n\\[\n\\int x\n\\]\n\nmore") == "text\n\n$$\n\\int x\n$$\n\nmore")
	}

	@Test func padsMidParagraphDisplayWithBlankLines() {
		#expect(transformMathDelimiters("mid \\[x^2\\] para") == "mid \n\n$$\nx^2\n$$\n\n para")
	}

	@Test func degradesIndentedDisplayToInline() {
		#expect(transformMathDelimiters("- item\n  \\[\n  x^2\n  \\]\n- next") == "- item\n  $$x^2$$\n- next")
	}

	@Test func leavesCurrencyUntouched() {
		let md = "It costs $5 and $10 more. $$big$$ sums too."
		#expect(transformMathDelimiters(md) == md)
	}

	@Test func leavesEscapedDelimitersUntouched() {
		#expect(transformMathDelimiters("escaped \\\\( and \\\\[ stay") == "escaped \\\\( and \\\\[ stay")
	}

	@Test func doesNotTransformInsideFencedCode() {
		let md = "```js\n\\(x\\) and \\[y\\]\n```"
		#expect(transformMathDelimiters(md) == md)
	}

	@Test func doesNotTransformInsideInlineCode() {
		let md = "run `\\(x\\)` locally"
		#expect(transformMathDelimiters(md) == md)
	}

	@Test func leavesUnbalancedDelimitersUntouched() {
		#expect(transformMathDelimiters("partial \\[ mid-stream") == "partial \\[ mid-stream")
		#expect(transformMathDelimiters("open \\( no close") == "open \\( no close")
	}

	@Test func stillConvertsALaterBalancedPair() {
		#expect(transformMathDelimiters("\\[ partial\n\nbut \\(ok\\)") == "\\[ partial\n\nbut $$ok$$")
	}

	// Escaped dollars inside math (owner, 2026-10-12).

	@Test func replacesEscapedDollarInsideBalancedInlineSpan() {
		#expect(transformMathDelimiters("It costs $x = \\$5$ at market.") == "It costs $x = \\text{\\textdollar}5$ at market.")
	}

	@Test func replacesEveryEscapedDollarIncludingTextForm() {
		#expect(
			transformMathDelimiters("$\\$3 + \\text{\\$}4 = \\$7$ exactly.")
				== "$\\text{\\textdollar}3 + \\text{\\text{\\textdollar}}4 = \\text{\\textdollar}7$ exactly."
		)
	}

	@Test func doesNotReplaceEvenBackslashDollars() {
		let md = "$a\\\\$b$ tail"
		#expect(transformMathDelimiters(md) == md)
	}

	@Test func leavesProseEscapedDollarsAndCurrency() {
		let md = "It costs \\$5 flat, then $5 and $10 more."
		#expect(transformMathDelimiters(md) == md)
	}

	@Test func leavesDisplaySpansUntouched() {
		let md = "$$x = \\$5,\\ q = \\$12$$"
		#expect(transformMathDelimiters(md) == md)
	}

	@Test func leavesCodeFencesAndUnbalancedSpans() {
		#expect(transformMathDelimiters("Type `$x = \\$5$` literally.") == "Type `$x = \\$5$` literally.")
		#expect(transformMathDelimiters("```\n$x = \\$5$\n```") == "```\n$x = \\$5$\n```")
		#expect(transformMathDelimiters("Broken: $x = \\$5") == "Broken: $x = \\$5")
	}

	@Test func cleanSpansStayByteIdentical() {
		#expect(transformMathDelimiters("$a$ costs $5\\$10$ and $b$") == "$a$ costs $5\\text{\\textdollar}10$ and $b$")
	}
}

@Suite struct HealOverescapedCommandsTests {
	@Test func healsDoubledLetterCommand() {
		#expect(healOverescapedCommands("$\\\\nabla f$") == "$\\nabla f$")
	}

	@Test func healsQuadrupledLetterCommand() {
		#expect(healOverescapedCommands("$\\\\\\\\mathbb{R}^n$") == "$\\mathbb{R}^n$")
	}

	@Test func healsInsideMultiLineDisplay() {
		#expect(healOverescapedCommands("$$\n\\\\nabla f(x)\n$$") == "$$\n\\nabla f(x)\n$$")
	}

	@Test func healsLegacySpans() {
		#expect(healOverescapedCommands("\\(\\\\nabla\\)") == "\\(\\nabla\\)")
	}

	@Test func healsPunctuationCommands() {
		#expect(healOverescapedCommands("$\\\\|u\\\\|_2$") == "$\\|u\\|_2$")
		#expect(healOverescapedCommands("$a\\\\,b$") == "$a\\,b$")
		#expect(healOverescapedCommands("$a\\\\;b$") == "$a\\;b$")
		#expect(healOverescapedCommands("$a\\\\:b$") == "$a\\:b$")
		#expect(healOverescapedCommands("$a\\\\!b$") == "$a\\!b$")
	}

	@Test func keepsLegitimateRowBreaks() {
		let matrix = "\\begin{pmatrix} 1 \\\\ 2 \\\\\\ 3\\end{pmatrix}"
		#expect(healOverescapedCommands(matrix) == matrix)
		let aligned = "f(x) \\\\& g(x) \\\\[6pt] h(x)"
		#expect(healOverescapedCommands(aligned) == aligned)
	}

	@Test func keepsOddRuns() {
		let cell = "$a \\\\\\nabla b$"
		#expect(healOverescapedCommands(cell) == cell)
	}

	@Test func touchesNothingOutsideMathSpans() {
		#expect(healOverescapedCommands("path C:\\\\Users\\\\amos") == "path C:\\\\Users\\\\amos")
		#expect(healOverescapedCommands("`$\\\\nabla$` in code") == "`$\\\\nabla$` in code")
		#expect(healOverescapedCommands("```\n$\\\\nabla$\n```") == "```\n$\\\\nabla$\n```")
	}

	@Test func unbalancedSpansPassThrough() {
		#expect(healOverescapedCommands("$\\\\nabla") == "$\\\\nabla")
	}
}

@Suite struct RestoreMathEscapesTests {
	@Test func keepsTheSixCharacterInlineRecoveryMap() {
		for (d, command) in [
			("\u{08}eta", "\\beta"), ("\to", "\\to"), ("\neq", "\\neq"),
			("\u{0B}arphi", "\\varphi"), ("\u{0C}orall", "\\forall"), ("\rho", "\\rho"),
		] {
			#expect(restoreMathEscapes("$" + d + "$") == "$" + command + "$")
		}
	}

	@Test func preservesDisplayNewlinesAndRowBreaks() {
		let math = "Compare:\n$$\n\\begin{aligned}\nx &= 1 \\\\\ny &= 2\n\\end{aligned}\n$$"
		#expect(restoreMathEscapes(math) == math)
	}

	@Test func restoresFiveDisplayDebrisCharsButKeepsNewlines() {
		for (d, command) in [
			("\u{08}eta", "\\beta"), ("\to", "\\to"), ("\u{0B}arphi", "\\varphi"),
			("\u{0C}orall", "\\forall"), ("\\left(x \right)", "\\left(x \\right)"),
		] {
			#expect(
				restoreMathEscapes("Compare:\n$$\n" + d + ", p \neq q\n$$")
					== "Compare:\n$$\n" + command + ", p \neq q\n$$"
			)
		}
	}

	@Test func preservesLegacyFirstMatchOnlyFrequency() {
		let body = "p\to q, \rho"
		let legacy = restoreMathEscapes("\\(" + body + "\\)").jsSlice(2, -2)
		#expect(restoreMathEscapes("$" + body + "$") == "$" + legacy + "$")
		#expect(legacy == "p\\to q, \rho", "the existing first-match-only behavior is unchanged")
	}

	@Test func leavesNonMathDebrisEscapedOpenersAndCode() {
		let prose = "Pasted:\t\u{0C}b. \\$\u{0C}orall x$. A good $x$."
		#expect(restoreMathEscapes(prose) == prose)
		let code = "Literal `$\u{0C}orall x$`.\n\n```text\n$\u{0B}arphi$\n```\n\nReal $\u{0C}orall x$."
		#expect(restoreMathEscapes(code) == code.replacing("Real $\u{0C}orall x$", with: "Real $\\forall x$"))
	}

	@Test(arguments: ["$\u{0C}orall", "$$\n\u{0C}orall x\n", "$\u{0C}orall$$", "$$\u{0C}orall$"])
	func leavesUnbalancedAndMismatchedRuns(text: String) {
		#expect(restoreMathEscapes(text) == text)
	}

	@Test func recognizesNativeInlineRunsAndLongerDisplayClosers() {
		#expect(restoreMathEscapes("Inline $$p\neq q$$.") == "Inline $$p\\neq q$$.")
		#expect(restoreMathEscapes("$$\n\u{0C}orall x\n$$$") == "$$\n\\forall x\n$$$")
	}

	@Test func noOverescapingRepairAndNoLegacyReprocess() {
		let overescaped = "$$\n\\\\Omega\n$$"
		#expect(restoreMathEscapes(overescaped) == overescaped)
		let legacy = "\\[\np $a\neq b$\n\\]"
		#expect(restoreMathEscapes(legacy) == legacy)
	}
}

/// tool-parts.test.ts parse-seam cases, ported as the per-string-field
/// repairMathForDisplay call the seam makes (restoreMathEscapesDeep).
@Suite struct MathParseSeamStringTests {
	@Test func restoresQuizDebrisInDollarMath() {
		#expect(repairMathForDisplay("What does $\u{0C}orall x$ mean?") == "What does $\\forall x$ mean?")
		#expect(repairMathForDisplay("$\u{0B}arphi$ holds") == "$\\varphi$ holds")
		#expect(repairMathForDisplay("Here $p\to q$ is an implication.") == "Here $p\\to q$ is an implication.")
	}

	@Test func sharesDollarRecoveryWithAskAndExplain() {
		#expect(repairMathForDisplay("$\u{0C}orall$ rigor") == "$\\forall$ rigor")
		#expect(repairMathForDisplay("Explain $p\to q$") == "Explain $p\\to q$")
		#expect(repairMathForDisplay("$p\neq q$ is different.") == "$p\\neq q$ is different.")
	}

	@Test func bareParensAreNotMath() {
		// JS "Because \(<FF>orall x\) holds." — `\(` in a JS literal is "(".
		let dirty = "Because (\u{0C}orall x) holds."
		#expect(repairMathForDisplay(dirty) == dirty)
	}

	private static let cleanQ = "Let $f : \\mathbb{R}^n \\to \\mathbb{R}$ be differentiable at $x$, with $\\nabla f(x) \\neq 0$. Among all unit directions $\\|u\\|_2 = 1$, which makes $D_u f(x)$ most negative?"
	private static func double(_ s: String) -> String { s.replacing("\\", with: "\\\\") }
	private static let options = ["$u^\\star = -\\nabla f(x)$", "$u^\\star = \\nabla f(x)$"]
	private static let explanation = "By Cauchy\u{2013}Schwarz: $$u^\\star = -\\frac{\\nabla f(x)}{\\|\\nabla f(x)\\|_2}$$"

	@Test func healsDoubledAndQuadrupledFieldsLeavingCleanSiblings() {
		#expect(repairMathForDisplay(Self.double(Self.cleanQ)) == Self.cleanQ)
		#expect(repairMathForDisplay(Self.double(Self.double(Self.cleanQ))) == Self.cleanQ)
		#expect(repairMathForDisplay(Self.options[0]) == Self.options[0])
		#expect(repairMathForDisplay(Self.explanation) == Self.explanation)
		#expect(repairMathForDisplay(Self.cleanQ) == Self.cleanQ)
	}

	@Test func healsDoubledOptionLabelsExplanationsAndAskDescriptions() {
		#expect(repairMathForDisplay(Self.double("$mkn$")) == "$mkn$")
		#expect(repairMathForDisplay(Self.double("$2mkn$")) == "$2mkn$")
		#expect(
			repairMathForDisplay(Self.double("$$c_{ij} = \\sum_{\\ell=1}^{k} a_{i\\ell}\\, b_{\\ell j}$$"))
				== "$$c_{ij} = \\sum_{\\ell=1}^{k} a_{i\\ell}\\, b_{\\ell j}$$"
		)
		#expect(repairMathForDisplay(Self.double("why $-\\nabla f$ is steepest descent")) == "why $-\\nabla f$ is steepest descent")
	}

	@Test func matrixRowBreaksSurvive() {
		let matrix = "Which matrix matches? $$\\begin{pmatrix} 1 \\ 2 \\\\ 3 \\ 4\\end{pmatrix}$$"
		#expect(repairMathForDisplay(matrix) == matrix)
	}
}

@Suite struct MathDelimitersGoldenTests {
	@Test func everyRowMatchesTS() throws {
		let rows = try #require(Golden.load("math.delimiters").arrayValue)
		#expect(rows.count > 100)
		for row in rows {
			let input = try #require(row["input"]?.stringValue)
			let outputs = try #require(row["outputs"])
			let source = row["source"]?.stringValue ?? "?"
			let actual: [(String, String)] = [
				("transformMathDelimiters", transformMathDelimiters(input)),
				("repairMathForDisplay", repairMathForDisplay(input)),
				("restoreMathEscapes", restoreMathEscapes(input)),
				("healOverescapedCommands", healOverescapedCommands(input)),
			]
			for (name, got) in actual {
				let expected = try #require(outputs[name]?.stringValue)
				// Compare code units: Swift `==` is canonical equivalence, JS is not.
				#expect(Array(got.utf16) == Array(expected.utf16), "\(name) [\(source)] input: \(JSONValue.quote(input).prefix(160))")
			}
		}
	}
}

// Deliberate divergence from math-delims.ts (owner, 2026-10-24): a clean
// inline span's closing `$` must not reopen a span over later delimiters.
@Suite struct CleanInlineSpanTests {
	@Test func laterLegacyDelimitersAndEscapesSurviveACleanSpan() {
		let src = #"inline $e^{i\pi} + 1 = 0$, legacy \(\nabla u\), and an escaped \$5 price."#
		#expect(transformMathDelimiters(src) == #"inline $e^{i\pi} + 1 = 0$, legacy $$\nabla u$$, and an escaped \$5 price."#)
	}
	@Test func aDisplayBlockAfterACleanSpanStillConverts() {
		let src = "a $x$ b\n\n\\[\ny\n\\]\n\nend $$"
		#expect(transformMathDelimiters(src) == "a $x$ b\n\n$$\ny\n$$\n\nend $$")
	}
}
