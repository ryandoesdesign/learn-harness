import AppKit
import SwiftUI
import Testing
@testable import Aster

// A `> [!IMPORTANT]` callout hugs short text but wraps long text inside the
// column (it once sized to its one-line ideal width and ran off the window).

@MainActor
@Suite struct CalloutLayoutTests {
	private let long = String(repeating: "Every strategic decision is a bet on a future world. ", count: 6)

	private func fitting<V: View>(_ view: V) -> CGSize {
		let host = NSHostingView(rootView: view)
		let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = host
		host.frame.size = host.fittingSize
		host.layoutSubtreeIfNeeded()
		return host.fittingSize
	}

	private func callout(_ body: String) -> CGSize {
		fitting(MarkdownView("> [!IMPORTANT]\n> \(body)", unit: "t").frame(width: 400).fixedSize(horizontal: false, vertical: true))
	}

	@Test func aLongCalloutWrapsInsideTheColumn() {
		let short = callout("Short.")
		let wrapped = callout(long)
		#expect(wrapped.height > short.height * 2, "the long callout wraps onto several lines: \(wrapped) vs \(short)")
	}

	@Test func shrinkToFitHugsShortTextAndCapsLongText() {
		let short = fitting(ShrinkToFit { Text("Short.") }.frame(maxWidth: 400))
		let capped = fitting(ShrinkToFit { Text(long).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: 400))
		#expect(short.width < 100, "short text hugs: \(short)")
		#expect(capped.width <= 400, "long text is capped at the column: \(capped)")
	}
}
