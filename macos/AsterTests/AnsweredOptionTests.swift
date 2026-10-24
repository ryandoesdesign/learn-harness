import AppKit
import LHCore
import LHStore
import SwiftUI
import Testing
@testable import Aster

// The answered option row's layout must not depend on its mark: the key
// (✓), a wrong pick (✗) and an unmarked option lay out the same, and a
// long label wraps inside the row's border instead of overflowing it. (An
// unmarked slot once held Color.clear, which has no text baseline: under
// .firstTextBaseline the label dropped below the border.)

@MainActor
@Suite struct AnsweredOptionLayoutTests {
	private let long = "Rows from both tables are combined wherever the join condition matches, and every unmatched row from either side is dropped from the result entirely"

	/// The row laid out in a real off-screen window at `width`.
	private func size(selected: Bool, key: Bool, quiz: Bool = true, width: CGFloat = 360) -> CGSize {
		let row = AnsweredOptionRow(opt: .init(index: 1, label: long), selected: selected, key: key, quiz: quiz, description: nil, unit: "t")
		let host = NSHostingView(rootView: row.frame(width: width).fixedSize(horizontal: false, vertical: true))
		let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width + 40, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = host
		host.frame.size = host.fittingSize
		host.layoutSubtreeIfNeeded()
		return host.fittingSize
	}

	@Test func everyMarkLaysOutTheSame() {
		let key = size(selected: false, key: true)
		let wrong = size(selected: true, key: false)
		let none = size(selected: false, key: false)
		let rightPick = size(selected: true, key: true)
		#expect(key.height == none.height, "✓ vs no mark: \(key) \(none)")
		#expect(wrong.height == none.height, "✗ vs no mark: \(wrong) \(none)")
		#expect(rightPick.height == none.height)
		#expect(key.height > 30, "the long label wraps onto several lines: \(key)")
	}

	/// Where the label's ink starts and ends, in a real window: the same for
	/// every mark, and inside the row.
	private func inkRows(selected: Bool, key: Bool) async throws -> (top: Int, bottom: Int, height: Int) {
		// Unselected labels are muted; draw the row selected-free and black so the label is the ink.
		let row = AnsweredOptionRow(opt: .init(index: 1, label: long), selected: selected, key: key, quiz: true, description: nil, unit: "t")
			.environment(\.colorScheme, .light)
		let host = NSHostingView(rootView: row.frame(width: 360).fixedSize(horizontal: false, vertical: true).background(Color.white))
		let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
		window.contentView = host
		host.frame.size = host.fittingSize
		window.setContentSize(host.fittingSize)
		host.layoutSubtreeIfNeeded()
		try await Task.sleep(for: .milliseconds(150))
		let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: rep)
		let scale = rep.pixelsWide / Int(host.bounds.width)
		// Label ink only: skip the mark's column (left 40pt) and the border's edges.
		var top = Int.max, bottom = -1
		for y in (2 * scale)..<(rep.pixelsHigh - 2 * scale) {
			for x in (40 * scale)..<(rep.pixelsWide - 4 * scale) {
				if let c = rep.colorAt(x: x, y: y), c.brightnessComponent < 0.75 { top = min(top, y); bottom = max(bottom, y); break }
			}
		}
		return (top / scale, bottom / scale, rep.pixelsHigh / scale)
	}

	@Test func theLabelSitsInTheSamePlaceForEveryMark() async throws {
		let none = try await inkRows(selected: false, key: false)
		let key = try await inkRows(selected: false, key: true)
		let wrong = try await inkRows(selected: true, key: false)
		#expect(none.top == key.top && wrong.top == key.top, "label tops: none \(none) key \(key) wrong \(wrong)")
		for r in [none, key, wrong] { #expect(r.bottom < r.height - 4, "the label ends inside the border: \(r)") }
	}

	@Test func aLongLabelStaysInsideTheColumn() {
		for (sel, key) in [(false, true), (true, false), (false, false)] {
			#expect(size(selected: sel, key: key).width <= 360, "sel \(sel) key \(key)")
		}
	}
}

