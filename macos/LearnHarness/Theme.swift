import SwiftUI

/// The transcript's registers (docs/native-macos-m4.md, "TS layout, system
/// type"): the TS app's structure and labels, drawn with system fonts and
/// semantic colors so light/dark and the accent follow the system.
enum Theme {
	/// The reading rung — `--lh-prose-size` (16px) in New York.
	static let proseSize: CGFloat = 16
	static let prose = Font.system(size: proseSize, design: .serif)
	/// Card body text (`text-sm`).
	static let small = Font.system(size: 13, design: .serif)
	/// The UI register (`font-ui text-xs`): SF Mono at the 11pt rung.
	static let ui = Font.system(size: 11, design: .monospaced)
	static let uiMedium = Font.system(size: 11, weight: .medium, design: .monospaced)
	static let mono = Font.system(size: 12, design: .monospaced)
	static let monoSmall = Font.system(size: 11, design: .monospaced)

	/// `bg-card`: the lifted surface for bands and cards.
	static let card = Color(nsColor: .controlBackgroundColor)
	static let border = Color(nsColor: .separatorColor)
	static let muted = Color.secondary
	static let faint = Color(nsColor: .tertiaryLabelColor)
	static let mutedFill = Color(nsColor: .quaternarySystemFill)
	static let green = Color(nsColor: .systemGreen)
	static let red = Color(nsColor: .systemRed)
	static let amber = Color(nsColor: .systemOrange)

	/// The rail the user's authorship carries (`border-l calc(3ch-14px)`).
	static let railWidth: CGFloat = 3 * 6.6 - 14
	static let railGap: CGFloat = 14
	static let column: CGFloat = 24
}

/// The eyebrow register: `text-xs font-medium uppercase tracking-wide`.
struct Eyebrow: View {
	var text: String
	var color: Color = Theme.muted
	init(_ text: String, color: Color = Theme.muted) {
		self.text = text
		self.color = color
	}
	var body: some View {
		Text(text.uppercased())
			.font(Theme.uiMedium)
			.tracking(0.6)
			.foregroundStyle(color)
	}
}

/// The quiz/outcome chip (`rounded px-1.5 py-0.5`, tinted).
struct Chip: View {
	var text: String
	var tint: Color?
	var body: some View {
		Text(text.uppercased())
			.font(Theme.uiMedium)
			.tracking(0.6)
			.foregroundStyle(tint ?? Theme.muted)
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(RoundedRectangle(cornerRadius: 4).fill((tint ?? .secondary).opacity(tint == nil ? 0.12 : 0.15)))
	}
}

/// `rounded-xl border bg-card p-4`.
struct CardModifier: ViewModifier {
	var padding: CGFloat = 16
	func body(content: Content) -> some View {
		content
			.padding(padding)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
			.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
	}
}

extension View {
	func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

/// The dotted boundary rule with a centered pill (PhaseDivider geometry).
struct DottedDivider: View {
	var label: String
	var body: some View {
		HStack(spacing: 12) {
			DottedRule()
			Text(label.uppercased())
				.font(Theme.uiMedium)
				.tracking(0.6)
				.foregroundStyle(Theme.muted)
				.padding(.horizontal, 10)
				.padding(.vertical, 2)
				.overlay(Capsule().strokeBorder(Theme.border))
			DottedRule()
		}
		.padding(.vertical, 16)
	}
}

struct DottedRule: View {
	var body: some View {
		GeometryReader { geo in
			Path { p in
				p.move(to: CGPoint(x: 0, y: 1))
				p.addLine(to: CGPoint(x: geo.size.width, y: 1))
			}
			.stroke(Theme.border, style: StrokeStyle(lineWidth: 2, dash: [2, 3]))
		}
		.frame(height: 2)
	}
}

/// A centered muted one-liner (chat.tsx SystemLine).
struct SystemLine: View {
	var text: String
	var body: some View {
		Text(text)
			.font(Theme.ui)
			.foregroundStyle(Theme.faint)
			.frame(maxWidth: .infinity)
			.padding(.vertical, 4)
	}
}

/// The trigger row's chevron (rotates when open).
struct Chevron: View {
	var open: Bool
	var body: some View {
		Image(systemName: "chevron.right")
			.font(.system(size: 9, weight: .semibold))
			.rotationEffect(.degrees(open ? 90 : 0))
			.foregroundStyle(Theme.muted)
	}
}
