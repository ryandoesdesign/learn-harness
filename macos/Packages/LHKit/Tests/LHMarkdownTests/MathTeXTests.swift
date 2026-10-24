import Foundation
import Testing
@testable import LHMarkdown

// The SwiftMath coverage the transcript relies on: KaTeX-isms with a
// faithful SwiftMath spelling are normalized; the known gaps stay errors
// (they render as the red raw-TeX fallback — docs/native-macos-m4.md, implementation notes).

@Suite struct MathTeXTests {
	@Test(arguments: [
		#"\tfrac{1}{3}"#, #"\dfrac{a}{b}"#, #"a\:b"#, #"\operatorname{argmax}_x f"#, #"\operatorname*{argmin}_x f"#,
		#"\boldsymbol{x}"#, #"\lVert x \rVert"#, #"a \pmod{n}"#, #"\varnothing"#, #"x \tag{1}"#, #"\implies"#,
		#"1, \dots, n"#, #"\big( x \big)"#, #"\Bigl[ x \Bigr]"#, #"\iint f"#, #"\emph{x}"#, #"\phantom{x}y"#,
		#"a \hspace{1em} b"#, #"\Box"#, #"\longmapsto"#, #"\begin{align} a &= b \\ c &= d \end{align}"#,
		#"\begin{align*} a &= b \end{align*}"#, #"\begin{equation} E = mc^2 \end{equation}"#,
		#"\begin{gathered} a \\ b \end{gathered}"#, #"\text{\textdollar}5"#,
		#"\int_0^1 x^2\,dx = \tfrac{1}{3}"#,
	])
	func normalizedKaTeXParses(_ tex: String) {
		#expect(mathParseError(tex) == nil, "\(tex) → \(normalizedTeX(tex))")
	}

	@Test func prefixesOfLongerCommandsAreUntouched() {
		#expect(normalizedTeX(#"\bigcup_i A_i"#) == #"\bigcup_i A_i"#)
		#expect(normalizedTeX(#"\dotsm"#) == #"\dotsm"#)
	}

	@Test func rowBreaksBeforeAColonStayRowBreaks() {
		#expect(normalizedTeX(#"a \\:b"#) == #"a \\:b"#)
		#expect(normalizedTeX(#"a \\\:b"#) == #"a \\\;b"#)
	}

	@Test(arguments: [
		#"\underbrace{x}_{a}"#, #"\overset{a}{b}"#, #"\underset{a}{b}"#, #"\stackrel{a}{=}"#, #"\xrightarrow{f}"#,
		#"\overrightarrow{AB}"#, #"\boxed{x}"#, #"\cancel{x}"#, #"\begin{array}{cc} 1 & 2 \end{array}"#, #"\checkmark"#, #"\vdash"#,
	])
	func knownGapsStayErrors(_ tex: String) {
		#expect(mathParseError(tex) != nil)
	}
}
