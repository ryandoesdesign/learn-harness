import AppKit
import LHCore
import LHWeb
import SwiftUI
import UniformTypeIdentifiers

/// steer-card.tsx: a sub-agent's delivery — never a learner bubble.
struct SteerCard: View {
	var message: ViewMessage
	var id: String

	var body: some View {
		Group {
			if let data = message.parts.first(where: { $0.type == "data-subagent-artifact" })?.data {
				let result = data["result"] ?? .null
				switch data["kind"]?.stringValue {
				case "research":
					if isFailure("Research failed", result) { BriefCard(kind: .research, result: result, id: id) }
					else { CompleteBadge(kind: .research, result: result, id: id) }
				case "pdf":
					if isFailure("PDF failed", result) { BriefCard(kind: .pdf, result: result, id: id) }
					else { CompleteBadge(kind: .pdf, result: result, id: id) }
				case "visual":
					FigureCard(result: result, messageId: message.id, initialInverted: data["ui"]?["inverted"]?.boolValue ?? false)
				case "demo":
					DemoPlaceholderCard(result: result)
				default:
					unreadable
				}
			} else if let aborted = message.parts.first(where: { $0.type == "data-subagent-aborted" })?.data {
				HStack(spacing: 8) {
					Image(systemName: "xmark.circle")
					Eyebrow(aborted["kind"]?.stringValue ?? "job")
					Text("aborted by the learner")
				}
				.font(Theme.ui)
				.foregroundStyle(Theme.muted)
			} else {
				unreadable
			}
		}
		.padding(.vertical, 4)
	}

	private var unreadable: some View {
		Text("A sub-agent finished, but its result could not be displayed.")
			.font(Theme.small).foregroundStyle(Theme.muted).card()
	}

	/// isSubagentFailure, read off the JSON (a brief that starts with the
	/// failure prefix, or no brief at all).
	private func isFailure(_ prefix: String, _ result: JSONValue) -> Bool {
		guard let brief = result["brief"]?.stringValue else { return true }
		return brief.hasPrefix(prefix)
	}
}

enum BriefKind {
	case research, pdf
	var badge: String { self == .research ? "Research" : "PDF" }
	var title: String { self == .research ? "Research brief" : "PDF brief" }
	var failurePrefix: String { self == .research ? "Research failed" : "PDF failed" }
	var unreadable: String { self == .research ? "Research completed, but the result could not be displayed." : "PDF reading completed, but the result could not be displayed." }
}

/// The delivery one-liner; expanding shows the brief.
struct CompleteBadge: View {
	var kind: BriefKind
	var result: JSONValue
	var id: String
	@Environment(SessionModel.self) private var session

	var body: some View {
		let open = session.isOpen(id)
		VStack(alignment: .leading, spacing: 8) {
			Button {
				session.setOpen(id, !open)
			} label: {
				HStack(spacing: 8) {
					Image(systemName: "checkmark")
					Eyebrow(kind.badge)
					Text(kind == .research ? "complete" : "reading complete")
					if let extra { Text("· \(extra)") }
					Text(open ? "hide brief" : "view brief").foregroundStyle(Theme.faint)
				}
				.font(Theme.ui)
				.foregroundStyle(Theme.muted)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			if open { BriefCard(kind: kind, result: result, id: id) }
		}
	}

	private var extra: String? {
		switch kind {
		case .research:
			let n = result["sources"]?.arrayValue?.count ?? 0
			return n > 0 ? "\(n) sources" : nil
		case .pdf:
			let read = result["pagesRead"]?.arrayValue ?? result["pagesConsulted"]?.arrayValue ?? []
			return read.isEmpty ? nil : "read \(read.count) page\(read.count == 1 ? "" : "s")"
		}
	}
}

/// job-card.tsx ResearchBriefCard / PdfBriefCard.
struct BriefCard: View {
	var kind: BriefKind
	var result: JSONValue
	var id: String

	var body: some View {
		if let brief = result["brief"]?.stringValue {
			let failed = brief.hasPrefix(kind.failurePrefix)
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 8) {
					Eyebrow(kind.title)
					if failed { Chip(text: "failed", tint: Theme.red) }
				}
				MarkdownView(brief, unit: "\(id).brief", font: Theme.small, fontSize: 13)
				footer(failed)
			}
			.card()
		} else {
			Text(kind.unreadable).font(Theme.small).foregroundStyle(Theme.muted).card()
		}
	}

	@ViewBuilder
	private func footer(_ failed: Bool) -> some View {
		switch kind {
		case .research:
			let sources = result["sources"]?.arrayValue ?? []
			if !sources.isEmpty {
				Divider().padding(.top, 8)
				Eyebrow("Sources")
				VStack(alignment: .leading, spacing: 2) {
					ForEach(Array(sources.enumerated()), id: \.offset) { _, s in
						if let url = s["url"]?.stringValue.flatMap(URL.init(string:)) {
							Link(s["title"]?.stringValue ?? url.absoluteString, destination: url).font(Theme.ui).lineLimit(1)
						}
					}
				}
			}
		case .pdf:
			let read = (result["pagesRead"]?.arrayValue ?? result["pagesConsulted"]?.arrayValue ?? []).compactMap(\.intValue)
			let consulted = (result["pagesConsulted"]?.arrayValue ?? []).compactMap(\.intValue)
			if !failed, !read.isEmpty {
				Divider().padding(.top, 8)
				Text("Pages read: \(read.map(String.init).joined(separator: ", "))").font(Theme.ui).foregroundStyle(Theme.muted)
			}
			if !failed, consulted.count > read.count {
				Divider().padding(.top, 8)
				Text("Pages consulted: \(consulted.map(String.init).joined(separator: ", "))").font(Theme.ui).foregroundStyle(Theme.muted)
			}
		}
	}
}

/// visual-card.tsx VisualOutputCard: no card chrome — the figure on its
/// white backing (natural width when declared), then the caption row:
/// FIGURE, invert, Download, Fullscreen. Invert is read-only in M4 (the
/// stored `message_ui` state seeds it; writing it back arrives with M5).
struct FigureCard: View {
	var result: JSONValue
	var messageId: String
	var initialInverted: Bool
	@Environment(SessionModel.self) private var session
	@Environment(SessionOverlays.self) private var overlays: SessionOverlays?
	@State private var inverted: Bool?
	@State private var rendered: RenderedSVG?
	@State private var renderError: String?

	var body: some View {
		let svg = session.artifactText(result, key: "svg")
		if let svg {
			if svg.isEmpty {
				VStack(alignment: .leading, spacing: 8) {
					HStack(spacing: 8) {
						Eyebrow("Figure")
						Chip(text: "failed", tint: Theme.red)
					}
					Text(result["notes"]?.stringValue ?? "The figure could not be drawn.").font(Theme.small).foregroundStyle(Theme.muted)
				}
				.card()
			} else {
				figure(svg)
			}
		} else {
			Text("Figure completed, but the result could not be displayed.").font(Theme.small).foregroundStyle(Theme.muted).card()
		}
	}

	private func figure(_ svg: String) -> some View {
		let isInverted = inverted ?? initialInverted
		let natural = svgNaturalWidth(svg)
		return VStack(alignment: .leading, spacing: 8) {
			Group {
				if let rendered {
					Image(nsImage: rendered.image)
						.resizable()
						.aspectRatio(rendered.size, contentMode: .fit)
						.frame(maxWidth: natural.map { CGFloat($0) } ?? .infinity)
						.colorInvertedHueRotated(isInverted)
						.clipShape(RoundedRectangle(cornerRadius: 8))
				} else if let renderError {
					Text(renderError).font(Theme.ui).foregroundStyle(Theme.red)
				} else {
					ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 64)
				}
			}
			HStack {
				Eyebrow("Figure")
				Spacer()
				Toggle(isOn: Binding(get: { isInverted }, set: { inverted = $0 })) {
					Image(systemName: "circle.lefthalf.filled")
				}
				.toggleStyle(.button)
				.help("Invert colors")
				Button {
					saveFile(name: "figure.svg", contents: svg, type: .svg)
				} label: { Image(systemName: "arrow.down.to.line") }
					.help("Download as SVG")
				if let overlays, let rendered {
					Button {
						overlays.openDiagram(svg: rendered.svg, size: rendered.size, figure: true, inverted: isInverted)
					} label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
						.help("Open fullscreen")
				}
			}
			.buttonStyle(.borderless)
			.controlSize(.small)
		}
		.frame(maxWidth: natural.map { CGFloat($0) } ?? .infinity)
		.frame(maxWidth: .infinity)
		.padding(.vertical, 12)
		.task(id: svg) {
			if let hit = WebRenderer.shared.cachedFigure(svg) {
				rendered = hit
				return
			}
			do { rendered = try await WebRenderer.shared.figure(svg) } catch { renderError = "\(error)" }
		}
	}
}

/// demo-card.tsx, M4 placeholder: the caption header (INTERACTIVE DEMO +
/// title) and Download (.html); the live sandboxed demo arrives with M6.
struct DemoPlaceholderCard: View {
	var result: JSONValue
	@Environment(SessionModel.self) private var session

	var body: some View {
		let html = session.artifactText(result, key: "html")
		let title = result["title"]?.stringValue
		if let html, let title {
			if html.isEmpty {
				VStack(alignment: .leading, spacing: 8) {
					HStack(spacing: 8) {
						Eyebrow("Interactive demo")
						Chip(text: "failed", tint: Theme.red)
					}
					Text(result["notes"]?.stringValue ?? "The demo could not be built.").font(Theme.small).foregroundStyle(Theme.muted)
				}
				.card()
			} else {
				VStack(alignment: .leading, spacing: 8) {
					HStack(spacing: 8) {
						Eyebrow("Interactive demo")
						Text(title).font(Theme.uiMedium).lineLimit(1)
						Spacer()
						Button {
							saveFile(name: "\(slugFilename(title)).html", contents: html, type: .html)
						} label: { Image(systemName: "arrow.down.to.line") }
							.buttonStyle(.borderless)
							.help("Download as HTML")
					}
					Text("The interactive demo view arrives with the background-jobs milestone (M6).")
						.font(Theme.small)
						.foregroundStyle(Theme.muted)
						.frame(maxWidth: .infinity, minHeight: 80)
						.background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
				}
				.padding(.vertical, 12)
			}
		} else {
			Text("Demo completed, but the result could not be displayed.").font(Theme.small).foregroundStyle(Theme.muted).card()
		}
	}
}

extension View {
	/// The figure invert filter: `invert(1) hue-rotate(180deg)`.
	@ViewBuilder
	func colorInvertedHueRotated(_ on: Bool) -> some View {
		if on { colorInvert().hueRotation(.degrees(180)) } else { self }
	}
}

/// The download affordance: a save panel for one text file.
@MainActor
func saveFile(name: String, contents: String, type: UTType) {
	let panel = NSSavePanel()
	panel.nameFieldStringValue = name
	panel.allowedContentTypes = [type]
	panel.canCreateDirectories = true
	guard panel.runModal() == .OK, let url = panel.url else { return }
	try? contents.write(to: url, atomically: true, encoding: .utf8)
}
