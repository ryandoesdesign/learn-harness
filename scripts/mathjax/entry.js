// The MathJax bundle for JavaScriptCore (docs/native-macos-m4.md): TeX in,
// standalone SVG out (glyphs as paths, no fonts, no DOM). Built by
// scripts/build-mathjax.sh into LHResources/Resources/mathjax-svg.js.

import {mathjax} from 'mathjax-full/js/mathjax.js';
import {TeX} from 'mathjax-full/js/input/tex.js';
import {SVG} from 'mathjax-full/js/output/svg.js';
import {liteAdaptor} from 'mathjax-full/js/adaptors/liteAdaptor.js';
import {RegisterHTMLHandler} from 'mathjax-full/js/handlers/html.js';
import {AllPackages} from 'mathjax-full/js/input/tex/AllPackages.js';

const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
// Every package except the ones that need async loading or a DOM.
const packages = AllPackages.filter((p) => !['autoload', 'require', 'bussproofs', 'noundefined'].includes(p));
const doc = mathjax.document('', {
	InputJax: new TeX({packages, formatError: (_jax, err) => { throw err; }}),
	OutputJax: new SVG({fontCache: 'local'}),
});

// tex → {svg, error}: the bare <svg> (glyph paths, no fonts needed).
globalThis.lhTex2Svg = (tex, display) => {
	try {
		const node = doc.convert(tex, {display, em: 16, ex: 8, containerWidth: 80 * 16});
		const svg = adaptor.firstChild(node);
		return {svg: inlineLineStyles(adaptor.outerHTML(svg)), error: null};
	} catch (e) {
		return {svg: null, error: String(e && e.message || e)};
	}
};

// MathJax styles table rules through its stylesheet (mtable > line[data-line]
// { stroke-width: 70px } plus dash patterns); a standalone SVG has none, so
// inline them.
function inlineLineStyles(svg) {
	return svg.replace(/<line data-line="([hv])" class="mjx-(solid|dashed|dotted)"/g, (_m, dir, kind) => {
		const dash = kind === 'dashed' ? ' stroke-dasharray="140"' : kind === 'dotted' ? ' stroke-dasharray="0,140" stroke-linecap="round"' : '';
		return `<line data-line="${dir}" class="mjx-${kind}" stroke-width="70" fill="none"${dash}`;
	});
}
