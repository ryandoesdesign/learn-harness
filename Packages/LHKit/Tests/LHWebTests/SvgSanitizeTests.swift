import Foundation
import Testing
@testable import LHWeb

// The figure card's pure helpers (visual-card.tsx sanitizeSvg /
// svgNaturalWidth) — the rendering itself is checked in the running app.

@Suite struct SvgSanitizeTests {
	@Test func stripsScriptsHandlersAndScriptLinks() {
		let dirty = #"<svg width="10"><script>alert(1)</script><script src="x"/><rect onclick="x()" onload='y'/><a href="javascript:z">a</a><a xlink:href='data:text/html,b'>b</a><a href="https://ok">c</a></svg>"#
		let clean = sanitizeSvg(dirty)
		#expect(!clean.contains("script"))
		#expect(!clean.contains("onclick") && !clean.contains("onload"))
		#expect(!clean.contains("javascript:") && !clean.contains("data:text/html"))
		#expect(clean.contains(#"href="https://ok""#))
	}
	@Test func naturalWidthReadsOnlyDeclaredPixels() {
		#expect(svgNaturalWidth(#"<svg width="640" height="10">"#) == 640)
		#expect(svgNaturalWidth(#"<svg width='320px'>"#) == 320)
		#expect(svgNaturalWidth(#"<svg width="100%">"#) == nil)
		#expect(svgNaturalWidth(#"<svg viewBox="0 0 1 1">"#) == nil)
		#expect(svgNaturalWidth(#"<svg width="0">"#) == nil)
	}
}
