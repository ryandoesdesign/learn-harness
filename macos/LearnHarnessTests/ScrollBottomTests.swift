import AppKit
import SwiftUI
import Testing
@testable import LearnHarness

// The reported bug (twice): the scroll-to-bottom button never went away. The
// at-bottom check must hold for the REAL geometry SwiftUI reports with the
// pinned dock (a bottom inset) AND the toolbar the transcript scrolls under
// (a top inset), measured in a live window.

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

/// The transcript's shape: a padded lazy column ending in the "bottom"
/// marker, the dock as a bottom inset, and a reader the test drives.
@MainActor
private final class ScrollDriver {
	var last: ScrollGeometry?
	var proxy: ScrollViewProxy?
	var position = ScrollPosition(edge: .bottom)
	var topInset: CGFloat = 0
}

private struct TranscriptShape: View {
	let driver: ScrollDriver
	@State private var position = ScrollPosition(edge: .bottom)
	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 16) {
					ForEach(0..<60, id: \.self) { Text("row \($0)").frame(height: 30) }
					Color.clear.frame(height: 1).id("bottom")
				}
				.padding(.horizontal, 20)
				.padding(.vertical, 16)
			}
			.scrollPosition($position)
			.defaultScrollAnchor(.bottom)
			.safeAreaInset(edge: .bottom, spacing: 0) { Color.red.frame(height: 150) }
			// The window toolbar: content scrolls under it (a top inset).
			.contentMargins(.top, driver.topInset, for: .scrollContent)
			.onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, g in driver.last = g }
			.onAppear { driver.proxy = proxy }
			.onChange(of: driver.position) { position = driver.position }
		}
		.frame(width: 300, height: 500)
	}
}

extension ScrollBottomTests {
	@Test(arguments: [0, 52] as [CGFloat])
	func scrollingToTheBottomMarkerCountsAsTheBottom(top: CGFloat) async throws {
		let driver = ScrollDriver()
		driver.topInset = top
		let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
		window.contentView = NSHostingView(rootView: TranscriptShape(driver: driver))
		window.orderFrontRegardless()
		defer { window.orderOut(nil) }
		try await Task.sleep(for: .milliseconds(400))
		let opened = try #require(driver.last)
		#expect(isBottom(opened), "opened at the bottom")
		driver.proxy?.scrollTo(0, anchor: .top)
		try await Task.sleep(for: .milliseconds(300))
		let up = try #require(driver.last)
		driver.proxy?.scrollTo("bottom", anchor: .bottom)
		try await Task.sleep(for: .milliseconds(400))
		let back = try #require(driver.last)
		#expect(!isBottom(up))
		#expect(isBottom(back), "the button's own scroll must land at what isBottom calls the bottom")
	}
}
