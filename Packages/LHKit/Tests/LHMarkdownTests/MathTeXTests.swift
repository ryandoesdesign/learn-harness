import Foundation
import Testing
@testable import LHMarkdown

// The math engine: MathJax in JavaScriptCore typesets the KaTeX-level TeX
// the transcript sees — including everything SwiftMath could not — and
// reports a clean error for broken input (the red raw-TeX fallback).

@Suite struct MathTeXTests {
	@Test(arguments: [
		#"\tfrac{1}{3}"#, #"\dfrac{a}{b}"#, #"a\:b"#, #"\operatorname{argmax}_x f"#, #"\operatorname*{argmin}_x f"#,
		#"\boldsymbol{x}"#, #"\lVert x \rVert"#, #"a \pmod{n}"#, #"\varnothing"#, #"\implies"#,
		#"1, \dots, n"#, #"\big( x \big)"#, #"\iint f"#, #"\begin{aligned} a &= b \\ c &= d \end{aligned}"#,
		#"\begin{gathered} a \\ b \end{gathered}"#, #"\int_0^1 x^2\,dx = \tfrac{1}{3}"#,
		#"\underbrace{x}_{a}"#, #"\overset{a}{b}"#, #"\underset{a}{b}"#, #"\stackrel{a}{=}"#, #"\xrightarrow{f}"#,
		#"\overrightarrow{AB}"#, #"\boxed{x}"#, #"\cancel{x}"#, #"\begin{array}{c|c} 1 & 2 \\ \hline 3 & 4 \end{array}"#,
		#"\checkmark"#, #"\vdash"#, #"\begin{cases} x & x > 0 \\ -x & \text{otherwise} \end{cases}"#,
	])
	func typesets(_ tex: String) {
		#expect(mathParseError(tex) == nil, "\(tex)")
	}

	@Test func theEscapedDollarFormTypesets() {
		#expect(mathParseError(#"x = \text{\textdollar}5"#) == nil)
		#expect(mathParseError(#"\text{\text{\textdollar}}12"#) == nil, "the transform's output inside \\text")
		#expect(normalizedTeX(#"\text{\textdollar}5"#) == #"\$5"#)
	}

	@Test func brokenTeXIsAnError() {
		#expect(mathParseError(#"\frac{1}{"#) != nil)
		#expect(mathParseError(#"\notacommand{x}"#) != nil)
	}

	@Test func geometryComesFromTheViewBox() throws {
		let r = try MathJax.shared.render(#"\int_0^1 x\,dx"#, display: true).get()
		#expect(r.widthEm > 1 && r.heightEm > 1)
		#expect(r.depthEm > 0.3, "the integral reaches below the baseline")
		let flat = try MathJax.shared.render("x", display: false).get()
		#expect(flat.depthEm < 0.05)
	}

	@Test func tableRulesCarryInlineStrokes() throws {
		let r = try MathJax.shared.render(#"\begin{array}{c|c} 1 & 2 \\ \hline 3 & 4 \end{array}"#, display: true).get()
		#expect(r.svg.contains(#"data-line="v" class="mjx-solid" stroke-width="70""#))
		#expect(r.svg.contains(#"data-line="h" class="mjx-solid" stroke-width="70""#))
	}
}
