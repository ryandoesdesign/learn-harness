import AppKit
import SwiftUI
import Testing
@testable import LearnHarness

// The reported bug: the scroll-to-bottom button never went away. The
// at-bottom check must hold for the REAL geometry SwiftUI reports with the
// pinned dock (a bottom safe-area inset), measured in a live window.

@MainActor
private final class GeoLog { var last: ScrollGeometry? }

private struct DockedScroll: View {
	let log: GeoLog
	var body: some View {
		ScrollView {
			VStack(spacing: 0) { ForEach(0..<100, id: \.self) { Text("row \($0)").frame(height: 30) } }
		}
		.defaultScrollAnchor(.bottom)
		.safeAreaInset(edge: .bottom, spacing: 0) { Color.red.frame(height: 150) }
		.onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, g in log.last = g }
		.frame(width: 300, height: 400)
	}
}

@MainActor
@Suite struct ScrollBottomTests {
	@Test func theBottomIsDetectedWithTheDockInset() async throws {
		let log = GeoLog()
		let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
		window.contentView = NSHostingView(rootView: DockedScroll(log: log))
		window.orderFrontRegardless()
		defer { window.orderOut(nil) }
		try await Task.sleep(for: .milliseconds(500))
		let g = try #require(log.last)
		#expect(g.contentInsets.bottom == 150, "the dock is an inset")
		#expect(isBottom(g), "opened at the bottom")
		var above = g
		above.contentOffset.y -= 200
		#expect(!isBottom(above), "200pt up is not the bottom")
	}
}
