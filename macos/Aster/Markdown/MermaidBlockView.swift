import LHWeb
import SwiftUI

/// The in-chat mermaid block (md-blocks MermaidInline): a spinner while the
/// fence is open or rendering, then the cached snapshot — width-capped at
/// its natural width so chart text never exceeds the prose size. Hover
/// corner: Copy (the source) and Expand (the live session overlay). On
/// failure: the error, the source, and Retry (MermaidError).
struct MermaidBlockView: View {
	var source: String
	var closed: Bool
	@Environment(\.colorScheme) private var scheme
	@Environment(SessionOverlays.self) private var overlays: SessionOverlays?
	@State private var rendered: RenderedSVG?
	@State private var error: String?
	@State private var attempt = 0
	@State private var hovered = false
	@State private var showSource = false

	var body: some View {
		Group {
			if !closed {
				spinner
			} else if let rendered {
				Image(nsImage: rendered.image)
					.resizable()
					.aspectRatio(rendered.size, contentMode: .fit)
					.frame(maxWidth: rendered.size.width)
					.frame(maxWidth: .infinity)
					.overlay(alignment: .topTrailing) { corner(rendered) }
					.onHover { hovered = $0 }
			} else if let error {
				failure(error)
			} else {
				spinner
			}
		}
		.task(id: TaskKey(source: source, dark: scheme == .dark, attempt: attempt, closed: closed)) {
			guard closed else { return }
			let dark = scheme == .dark
			if let hit = WebRenderer.shared.cachedMermaid(source, dark: dark) {
				rendered = hit
				return
			}
			rendered = nil
			error = nil
			do {
				rendered = try await WebRenderer.shared.mermaid(source, dark: dark)
			} catch {
				self.error = "\(error)"
			}
		}
	}

	private struct TaskKey: Equatable {
		var source: String
		var dark: Bool
		var attempt: Int
		var closed: Bool
	}

	private var spinner: some View {
		ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 48)
	}

	private func corner(_ r: RenderedSVG) -> some View {
		HStack(spacing: 2) {
			Button {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(source, forType: .string)
			} label: { Image(systemName: "doc.on.doc").frame(width: 24, height: 24).contentShape(Rectangle()) }
				.help("Copy diagram source")
			if let overlays {
				Button {
					overlays.openDiagram(svg: r.svg, size: r.size, figure: false, inverted: false)
				} label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 24, height: 24).contentShape(Rectangle()) }
					.help("Open full-screen")
			}
		}
		.buttonStyle(.plain)
		.font(.system(size: 11))
		.foregroundStyle(Theme.muted)
		.opacity(hovered ? 1 : 0)
		.padding(4)
	}

	private func failure(_ message: String) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Diagram failed to render").font(Theme.uiMedium).foregroundStyle(Theme.red)
			Text(message).font(Theme.monoSmall).foregroundStyle(Theme.muted).textSelection(.enabled)
			DisclosureGroup("Show diagram source", isExpanded: $showSource) {
				Text(source).font(Theme.monoSmall).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
			}
			.font(Theme.ui)
			Button("Retry") { attempt += 1 }.controlSize(.small)
		}
		.card(padding: 12)
	}
}
