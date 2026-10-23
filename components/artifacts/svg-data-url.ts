/**
 * Model-authored SVG as an <img> source (security hardening, 2026-10-24).
 * Browsers never run scripts or fetch external resources from an SVG
 * loaded through <img>, so the figure needs no sanitizer — unlike the old
 * inline dangerouslySetInnerHTML path, whose regex filter was bypassable.
 */
export function svgDataUrl(svg: string): string {
	return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}
