import AppKit
import Foundation
import LHWeb
import Testing
@testable import LearnHarness

// The shared WebKit renderer in the real host: mermaid renders and
// snapshots in both themes, a broken chart reports mermaid's error, and a
// figure renders at its declared width with scripts stripped.

@MainActor
@Suite(.serialized) struct WebRendererTests {
	@Test func mermaidRendersAndSnapshots() async throws {
		for dark in [false, true] {
			let r = try await WebRenderer.shared.mermaid("graph TD\n  A[Probe] --> B[Plan]\n  B --> C[Teach]", dark: dark)
			#expect(r.svg.contains("<svg"))
			#expect(r.size.width > 20 && r.size.height > 20)
			#expect(r.image.size.width > 0)
			#expect(inkedPixels(r.image) > 100, "the snapshot is blank")
			#expect(WebRenderer.shared.cachedMermaid("graph TD\n  A[Probe] --> B[Plan]\n  B --> C[Teach]", dark: dark) != nil)
		}
	}

	@Test func aBrokenChartReportsTheError() async {
		await #expect(throws: WebRenderError.self) {
			_ = try await WebRenderer.shared.mermaid("not a diagram @@@\nA --> B", dark: false)
		}
	}

	@Test func figureRendersAtItsDeclaredWidth() async throws {
		let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="320" height="140"><script>alert(1)</script><rect width="100" height="100" fill="red"/></svg>"#
		let r = try await WebRenderer.shared.figure(svg)
		#expect(!r.svg.contains("script"))
		#expect(abs(r.size.width - 320) < 1)
		#expect(abs(r.size.height - 140) < 1)
	}

	@Test func mathImagesRenderForInlineAndDisplay() {
		#expect(MathImage.render(#"e^{i\pi} + 1 = 0"#, size: 16, display: false) != nil)
		#expect(MathImage.render(#"\int_0^1 x^2\,dx = \tfrac{1}{3}"#, size: 17.6, display: true) != nil)
		#expect(MathImage.render(#"\underbrace{x}_{n}"#, size: 16, display: false) == nil)
	}
}

/// Pixels with any opacity — a blank (all-transparent) snapshot has none.
@MainActor
private func inkedPixels(_ image: NSImage) -> Int {
	guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
	let w = cg.width, h = cg.height
	var data = [UInt8](repeating: 0, count: w * h * 4)
	guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
		space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
	ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
	return stride(from: 3, to: data.count, by: 4).reduce(0) { $0 + (data[$1] > 0 ? 1 : 0) }
}
