import AppKit
import SwiftUI
import Testing
@testable import Aster

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

// The dock growing (a question expanding) must not cover the transcript:
// at the bottom the view stays at the bottom; scrolled up, the rows that
// were on screen stay on screen.

@MainActor
@Observable private final class DockDriver {
	var dock: CGFloat = 80
	var atBottom = true
	var last: ScrollGeometry?
	var proxy: ScrollViewProxy?
	var scrollY: CGFloat?
}

private struct GrowingDock: View {
	let driver: DockDriver
	@State private var position = ScrollPosition(edge: .bottom)
	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0) {
					ForEach(0..<60, id: \.self) { Text("row \($0)").frame(height: 30).id($0) }
					Color.clear.frame(height: 1).id("bottom")
				}
			}
			.scrollPosition($position)
			.defaultScrollAnchor(.bottom)
			.safeAreaInset(edge: .bottom, spacing: 0) { Color.red.frame(height: driver.dock) }
			.followsBottomInset(position: $position, atBottom: driver.atBottom) { proxy.scrollTo("bottom", anchor: .bottom) }
			.onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, g in driver.last = g }
			.onAppear { driver.proxy = proxy }
			.onChange(of: driver.scrollY) { if let y = driver.scrollY { position.scrollTo(y: y) } }
		}
		.frame(width: 300, height: 500)
	}
}

extension ScrollBottomTests {
	private func show(_ driver: DockDriver) async throws -> NSWindow {
		let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = NSHostingView(rootView: GrowingDock(driver: driver))
		window.orderFrontRegardless()
		try await Task.sleep(for: .milliseconds(400))
		return window
	}

	@Test func aGrowingDockKeepsTheBottomInView() async throws {
		let driver = DockDriver()
		let window = try await show(driver)
		defer { window.orderOut(nil) }
		#expect(isBottom(try #require(driver.last)))
		driver.dock = 380
		try await Task.sleep(for: .milliseconds(400))
		let g = try #require(driver.last)
		#expect(g.contentInsets.bottom == 380)
		#expect(isBottom(g), "the last rows sit above the expanded dock: \(g)")
	}

	@Test func aGrowingDockShiftsAScrolledUpTranscript() async throws {
		let driver = DockDriver()
		let window = try await show(driver)
		defer { window.orderOut(nil) }
		driver.atBottom = false
		driver.proxy?.scrollTo(20, anchor: .top)
		try await Task.sleep(for: .milliseconds(300))
		let before = try #require(driver.last).contentOffset.y
		driver.dock = 280
		try await Task.sleep(for: .milliseconds(400))
		let after = try #require(driver.last).contentOffset.y
		#expect(abs(after - before - 200) < 1, "the offset moves by the dock's growth: \(before) → \(after)")
	}

	/// "At the bottom" allows 24pt of slack; the scroll view's own bottom
	/// anchor only holds at the exact bottom, so 10pt up it would let the dock cover.
	@Test func aGrowingDockKeepsTheBottomInViewFromNearTheBottom() async throws {
		let driver = DockDriver()
		let window = try await show(driver)
		defer { window.orderOut(nil) }
		driver.scrollY = try #require(driver.last).contentOffset.y - 10
		try await Task.sleep(for: .milliseconds(300))
		#expect(isBottom(try #require(driver.last)), "10pt up still counts as the bottom")
		driver.dock = 380
		try await Task.sleep(for: .milliseconds(400))
		#expect(isBottom(try #require(driver.last)), "\(driver.last!)")
	}
}
