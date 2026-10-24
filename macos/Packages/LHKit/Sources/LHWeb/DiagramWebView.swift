import AppKit
import SwiftUI
import WebKit

/// The live diagram for the session overlay: the SVG in a WKWebView with
/// page scripts off and no network, transformed by the native pan/zoom
/// state (CSS transform — stays vector-crisp at any zoom). It never takes
/// pointer events; the overlay's gesture surface sits above it.
public struct DiagramWebView: NSViewRepresentable {
	public var svg: String
	/// The natural size the SVG is laid out at (points).
	public var size: CGSize
	/// Viewport translate + scale, in overlay coordinates.
	public var zoom: Double
	public var x: Double
	public var y: Double
	/// Figures sit on white; `inverted` flips brightness (the figure toggle).
	public var whiteBacking: Bool
	public var inverted: Bool
	/// Eases transform changes (the TS overlay's 180ms transition).
	public var animated: Bool

	public init(svg: String, size: CGSize, zoom: Double, x: Double, y: Double, whiteBacking: Bool = false, inverted: Bool = false, animated: Bool = true) {
		self.svg = svg
		self.size = size
		self.zoom = zoom
		self.x = x
		self.y = y
		self.whiteBacking = whiteBacking
		self.inverted = inverted
		self.animated = animated
	}

	public final class Coordinator: NSObject, WKNavigationDelegate {
		var loadedSVG: String?
		var ready = false
		var pending: String?

		public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			ready = true
			if let pending { webView.evaluateJavaScript(pending) }
			pending = nil
		}

		public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
			navigationAction.navigationType == .other ? .allow : .cancel
		}
	}

	public func makeCoordinator() -> Coordinator { Coordinator() }

	public func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.websiteDataStore = .nonPersistent()
		config.defaultWebpagePreferences.allowsContentJavaScript = false
		let view = PassthroughWebView(frame: .zero, configuration: config)
		view.setValue(false, forKey: "drawsBackground")
		view.navigationDelegate = context.coordinator
		return view
	}

	public func updateNSView(_ view: WKWebView, context: Context) {
		let c = context.coordinator
		if c.loadedSVG != svg {
			c.loadedSVG = svg
			c.ready = false
			let backing = whiteBacking ? "background:#fff;" : ""
			let html = """
				<!doctype html><html><head><meta charset="utf-8">
				<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:">
				<style>html,body{margin:0;padding:0;overflow:hidden;background:transparent}
				#c{position:absolute;left:0;top:0;transform-origin:0 0;width:\(size.width)px;height:\(size.height)px;\(backing)}
				#c svg{display:block;width:100%;height:100%;max-width:none}</style>
				</head><body><div id="c">\(svg)</div></body></html>
				"""
			view.loadHTMLString(html, baseURL: nil)
		}
		let filter = inverted ? "invert(1) hue-rotate(180deg)" : "none"
		let transition = animated ? "transform 180ms ease-out" : "none"
		let js = "(() => { const c = document.getElementById('c'); c.style.transition = '\(transition)'; c.style.transform = 'translate(\(x)px, \(y)px) scale(\(zoom))'; c.style.filter = '\(filter)'; })()"
		if c.ready { view.evaluateJavaScript(js) } else { c.pending = js }
	}
}

/// Never the hit-test target: gestures belong to the overlay surface.
private final class PassthroughWebView: WKWebView {
	override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
