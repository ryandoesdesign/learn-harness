import AppKit
import Foundation
import LHMarkdown
import LHWeb
import SwiftUI
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
		#expect(MathImage.render(#"\int_0^1 x^2\,dx = \tfrac{1}{3}"#, size: 16, display: true) != nil)
		#expect(MathImage.render(#"\underbrace{x}_{n}"#, size: 16, display: false) != nil)
		#expect(MathImage.render(#"\frac{1}{"#, size: 16, display: false) == nil)
	}
}

/// The inline-math clipping bug: an expression that reaches below the
/// baseline must draw whole inside the paragraph, not just its top half.
@MainActor
@Suite struct InlineMathClipTests {
	@Test func inlineMathDrawsItsFullHeight() throws {
		let tex = #"\int_0^1 \frac{x}{y}\,dx"#
		let math = try #require(MathImage.render(tex, size: Theme.proseSize, display: false))
		let view = InlineText(runs: [.math(tex)], unit: "u", font: Theme.prose, fontSize: Theme.proseSize)
			.frame(width: 400)
			.foregroundStyle(.black)
		let renderer = ImageRenderer(content: view)
		renderer.scale = 1
		let image = try #require(renderer.nsImage)
		let rows = inkedRows(image)
		#expect(Double(rows) >= Double(math.image.size.height) - 2, "ink \(rows)pt of \(math.image.size.height)pt drawn")
	}

	@Test func displayMathDrawsItsFullHeight() async throws {
		let tex = #"\sum_{i=1}^{n} \frac{1}{i^2} = \int_0^1 f(x)\,dx"#
		let math = try #require(MathImage.render(tex, size: Theme.proseSize, display: true))
		let rows = try await windowInkRows(DisplayMathView(tex: tex, closed: true, fontSize: Theme.proseSize))
		let bare = try await windowInkRows(Image(nsImage: math.image))
		#expect(abs(rows - bare) <= 1, "ink \(rows)pt in the block vs \(bare)pt for the bare image")
	}

	@Test func inlineMathInARowDrawsItsFullHeight() async throws {
		let tex = #"\int_0^1 \frac{x}{y}\,dx"#
		let math = try #require(MathImage.render(tex, size: Theme.proseSize, display: false))
		let rows = try await windowInkRows(BlockView(block: .paragraph([.math(tex)]), unit: "u", font: Theme.prose, fontSize: Theme.proseSize))
		let bare = try await windowInkRows(Image(nsImage: math.image))
		#expect(abs(rows - bare) <= 1, "ink \(rows)pt in the paragraph vs \(bare)pt for the bare image")
	}
}

extension InlineMathClipTests {
	/// The measurement itself catches a clip (guards the guard).
	@Test func aHalfClippedImageIsDetected() async throws {
		let math = try #require(MathImage.render(#"\int_0^1 f(x)\,dx"#, size: Theme.proseSize, display: true))
		let clipped = try await windowInkRows(Image(nsImage: math.image).frame(height: math.image.size.height / 2, alignment: .top).clipped())
		let bare = try await windowInkRows(Image(nsImage: math.image))
		#expect(clipped < bare - 5)
	}
}

/// Ink rows of a view laid out in a real (off-screen) window — unlike
/// ImageRenderer, this draws platform views such as ScrollView.
@MainActor
func windowInkRows(_ view: some View) async throws -> Int {
	let host = NSHostingView(rootView: view.frame(width: 500).fixedSize(horizontal: false, vertical: true).foregroundStyle(.black).padding(10).background(Color.white))
	let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 520, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
	window.contentView = host
	host.frame.size = host.fittingSize
	window.setContentSize(host.fittingSize)
	host.layoutSubtreeIfNeeded()
	try await Task.sleep(for: .milliseconds(200))
	let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
	host.cacheDisplay(in: host.bounds, to: rep)
	var count = 0
	for y in 0..<rep.pixelsHigh {
		for x in 0..<rep.pixelsWide {
			if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.5 { count += 1; break }
		}
	}
	return count / Int(max(1, rep.pixelsHigh / Int(host.bounds.height)))
}

/// Horizontal scroll views must take their content's height (code and
/// tables share the display-math wrapper).
@MainActor
@Suite struct HorizontalScrollHeightTests {
	private func height(_ view: some View) throws -> CGFloat {
		let renderer = ImageRenderer(content: view.frame(width: 500))
		renderer.scale = 1
		return try #require(renderer.nsImage).size.height
	}

	@Test func codeBlocksShowEveryLine() throws {
		let source = (1...12).map { "line \($0)" }.joined(separator: "\n")
		let h = try height(CodeBlockView(language: "text", source: source, startLine: nil, lineNumbers: true, unit: "u"))
		#expect(h > 12 * 13, "a 12-line block is \(h)pt tall")
	}

	@Test func tablesShowEveryRow() throws {
		let cell: [MDInline] = [.text("cell")]
		let h = try height(TableBlock(header: [cell, cell], rows: Array(repeating: [cell, cell], count: 6), alignments: [nil, nil], unit: "u", font: Theme.prose, fontSize: Theme.proseSize))
		#expect(h > 7 * 24, "a 7-row table is \(h)pt tall")
	}
}

/// Rows containing any ink.
@MainActor
private func inkedRows(_ image: NSImage) -> Int {
	guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
	let w = cg.width, h = cg.height
	var data = [UInt8](repeating: 0, count: w * h * 4)
	guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
		space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
	ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
	var count = 0
	for y in 0..<h where (0..<w).contains(where: { data[(y * w + $0) * 4 + 3] > 40 }) { count += 1 }
	return count
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
