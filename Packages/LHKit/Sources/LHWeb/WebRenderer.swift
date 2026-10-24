import AppKit
import Foundation
import LHResources
import WebKit

// The shared hidden WebKit renderer (docs/native-macos-m4.md): mermaid
// diagrams and figure SVGs are rendered once, snapshotted to images, and
// cached — the transcript holds no live web views. Non-persistent data
// store, a CSP that forbids every network load, and (for figures) page
// JavaScript off.

/// A rendered diagram: the SVG markup (for the live overlay and copy) and
/// its snapshot at natural size.
public struct RenderedSVG: @unchecked Sendable {
	public var svg: String
	public var image: NSImage
	/// Natural size in points.
	public var size: CGSize
}

public enum WebRenderError: Error, CustomStringConvertible, Sendable {
	case mermaid(String)
	case snapshot(String)
	public var description: String {
		switch self {
		case .mermaid(let m): m
		case .snapshot(let m): "Snapshot failed: \(m)"
		}
	}
}

/// mermaid's base font size — the transcript caps a diagram's display width
/// at its natural width, so chart text never exceeds this (mermaid-render.ts).
public let MERMAID_FONT_SIZE = 16.0

@MainActor
public final class WebRenderer {
	public static let shared = WebRenderer()

	private struct Key: Hashable {
		var kind: Int
		var source: String
		var dark: Bool
	}

	private var cache: [Key: RenderedSVG] = [:]
	private var inFlight: [Key: Task<RenderedSVG, Error>] = [:]
	/// Renders run one at a time on the shared views.
	private var tail: Task<Void, Never>?

	private let window: NSWindow
	private lazy var mermaidView = makeView(javaScript: true)
	private lazy var figureView = makeView(javaScript: false)
	private var mermaidLoaded = false
	private let waiter = NavigationWaiter()

	private init() {
		// Off-screen host: WebKit only paints views that live in a window.
		window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
		window.isReleasedWhenClosed = false
		window.alphaValue = 0
		window.ignoresMouseEvents = true
	}

	/// The cached render, if any (synchronous — first paint uses it).
	public func cachedMermaid(_ source: String, dark: Bool) -> RenderedSVG? {
		cache[Key(kind: 0, source: source, dark: dark)]
	}

	public func cachedFigure(_ svg: String) -> RenderedSVG? {
		cache[Key(kind: 1, source: svg, dark: false)]
	}

	/// Render a mermaid chart (theme follows the appearance).
	public func mermaid(_ source: String, dark: Bool) async throws -> RenderedSVG {
		try await render(Key(kind: 0, source: source, dark: dark)) { [unowned self] in
			try await self.renderMermaid(source, dark: dark)
		}
	}

	/// Render a figure SVG (sanitized, page scripts off) on its white backing.
	public func figure(_ svg: String) async throws -> RenderedSVG {
		try await render(Key(kind: 1, source: svg, dark: false)) { [unowned self] in
			try await self.renderFigure(svg)
		}
	}

	private func render(_ key: Key, _ work: @escaping @MainActor () async throws -> RenderedSVG) async throws -> RenderedSVG {
		if let hit = cache[key] { return hit }
		if let running = inFlight[key] { return try await running.value }
		let previous = tail
		let task = Task { @MainActor () throws -> RenderedSVG in
			await previous?.value
			return try await work()
		}
		inFlight[key] = task
		tail = Task { _ = try? await task.value }
		defer { inFlight[key] = nil }
		let result = try await task.value
		cache[key] = result
		return result
	}

	private func makeView(javaScript: Bool) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.websiteDataStore = .nonPersistent()
		config.defaultWebpagePreferences.allowsContentJavaScript = javaScript
		let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
		view.setValue(false, forKey: "drawsBackground")
		view.navigationDelegate = waiter
		window.contentView?.addSubview(view)
		return view
	}

	private static let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:"

	private func renderMermaid(_ source: String, dark: Bool) async throws -> RenderedSVG {
		let view = mermaidView
		if !mermaidLoaded {
			let js = try LHResources.mermaidJS
			let html = """
				<!doctype html><html><head><meta charset="utf-8">
				<meta http-equiv="Content-Security-Policy" content="\(Self.csp)">
				<style>html,body{margin:0;padding:0;background:transparent}#out{display:inline-block}</style>
				<script>\(js)</script></head><body><div id="out"></div></body></html>
				"""
			view.loadHTMLString(html, baseURL: nil)
			try await waiter.wait()
			mermaidLoaded = true
		}
		let script = """
			mermaid.initialize({startOnLoad: false, theme: theme, securityLevel: "strict",
				fontFamily: "ui-sans-serif, system-ui, sans-serif", fontSize: fontSize});
			const id = "lh-mermaid-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 9);
			try {
				const { svg } = await mermaid.render(id, source);
				const out = document.getElementById("out");
				out.innerHTML = svg;
				const el = out.querySelector("svg");
				const vb = el.viewBox && el.viewBox.baseVal;
				const w = vb && vb.width ? vb.width : el.getBoundingClientRect().width;
				const h = vb && vb.height ? vb.height : el.getBoundingClientRect().height;
				el.style.maxWidth = "none";
				el.setAttribute("width", w);
				el.setAttribute("height", h);
				return { ok: true, svg: svg, w: w, h: h };
			} catch (e) {
				document.querySelectorAll("[id^='dlh-mermaid']").forEach((n) => n.remove());
				return { ok: false, error: String(e && e.message || e) };
			}
			"""
		let raw = try await view.callAsyncJavaScript(script, arguments: [
			"source": source, "theme": dark ? "dark" : "default", "fontSize": MERMAID_FONT_SIZE,
		], contentWorld: .page)
		guard let result = raw as? [String: Any] else { throw WebRenderError.mermaid("No result") }
		guard result["ok"] as? Bool == true, let svg = result["svg"] as? String,
		      let w = result["w"] as? Double, let h = result["h"] as? Double
		else { throw WebRenderError.mermaid(result["error"] as? String ?? "Diagram failed to render") }
		let size = CGSize(width: ceil(w), height: ceil(h))
		let image = try await snapshot(view, size: size)
		return RenderedSVG(svg: svg, image: image, size: size)
	}

	private func renderFigure(_ svg: String) async throws -> RenderedSVG {
		let view = figureView
		let clean = sanitizeSvg(svg)
		let width = svgNaturalWidth(clean)
		let html = """
			<!doctype html><html><head><meta charset="utf-8">
			<meta http-equiv="Content-Security-Policy" content="\(Self.csp.replacingOccurrences(of: "script-src 'unsafe-inline'; ", with: ""))">
			<style>html,body{margin:0;padding:0;background:#fff}#out{display:inline-block;\(width.map { "width:\($0)px" } ?? "width:720px")}#out svg{display:block;max-width:100%;height:auto}</style>
			</head><body><div id="out">\(clean)</div></body></html>
			"""
		view.loadHTMLString(html, baseURL: nil)
		try await waiter.wait()
		let measured = try await view.evaluateJavaScript("(() => { const r = document.getElementById('out').getBoundingClientRect(); return [r.width, r.height]; })()")
		guard let dims = measured as? [Double], dims.count == 2, dims[0] > 0, dims[1] > 0 else { throw WebRenderError.snapshot("Figure has no size") }
		let size = CGSize(width: ceil(dims[0]), height: ceil(dims[1]))
		let image = try await snapshot(view, size: size)
		return RenderedSVG(svg: clean, image: image, size: size)
	}

	private func snapshot(_ view: WKWebView, size: CGSize) async throws -> NSImage {
		view.frame = NSRect(origin: .zero, size: CGSize(width: max(size.width, 1), height: max(size.height, 1)))
		window.setContentSize(view.frame.size)
		let config = WKSnapshotConfiguration()
		config.rect = view.bounds
		config.afterScreenUpdates = true
		return try await view.takeSnapshot(configuration: config)
	}
}

/// One navigation at a time: `wait()` resumes on the next finish or failure.
@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
	private var continuation: CheckedContinuation<Void, Error>?

	func wait() async throws {
		try await withCheckedThrowingContinuation { continuation = $0 }
	}

	func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
		continuation?.resume()
		continuation = nil
	}

	func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
		continuation?.resume(throwing: error)
		continuation = nil
	}

	func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
		continuation?.resume(throwing: error)
		continuation = nil
	}

	/// Only the initial document load is allowed; links never navigate.
	func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
		navigationAction.navigationType == .other ? .allow : .cancel
	}
}

/// Port of visual-card.tsx `sanitizeSvg`: strip scripts, inline handlers and
/// javascript:/data:text/html links.
public func sanitizeSvg(_ svg: String) -> String {
	var s = svg
	s = s.replacing(/(?i)<script[\s\S]*?<\/script\s*>/, with: "")
	s = s.replacing(/(?i)<script[^>]*\/?>/, with: "")
	s = s.replacing(/(?i)\son[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/, with: "")
	s = s.replacing(/(?i)(href|xlink:href)\s*=\s*(?:"\s*(?:javascript|data:text\/html)[^"]*"|'\s*(?:javascript|data:text\/html)[^']*'|(?:javascript|data:text\/html)[^\s>]*)/, with: "")
	return s
}

/// Port of `svgNaturalWidth`: the svg root's declared px width, or nil.
public func svgNaturalWidth(_ svg: String) -> Double? {
	guard let m = svg.firstMatch(of: /(?i)<svg\b[^>]*?\bwidth\s*=\s*["']([^"']+)["'][^>]*>/) else { return nil }
	let value = m.1.trimmingCharacters(in: .whitespaces)
	guard let px = value.wholeMatch(of: /(?i)(\d+(?:\.\d+)?)(?:px)?/), let n = Double(px.1), n.isFinite, n > 0 else { return nil }
	return n
}
