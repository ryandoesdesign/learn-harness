import { chat, TEACH_CHAT, PRACTICE_CHAT } from "./_fixtures.ts";
import {
	healOverescapedCommands,
	repairMathForDisplay,
	restoreMathEscapes,
	transformMathDelimiters,
} from "../../src/core/math-delims.ts";

/** Every string value inside a tool-call argument tree. */
function strings(value: unknown, out: string[]): void {
	if (typeof value === "string") out.push(value);
	else if (Array.isArray(value)) for (const v of value) strings(v, out);
	else if (value && typeof value === "object") for (const v of Object.values(value)) strings(v, out);
}

/** Text, thinking, tool-argument strings and tool-result text of a chat. */
function chatTexts(id: string): string[] {
	const out: string[] = [];
	// eslint-disable-next-line @typescript-eslint/no-explicit-any
	for (const m of chat(id).messages as any[]) {
		if (m.role !== "user" && m.role !== "assistant" && m.role !== "toolResult") continue;
		if (typeof m.content === "string") {
			out.push(m.content);
			continue;
		}
		for (const b of m.content ?? []) {
			if (b.type === "text") out.push(b.text);
			else if (b.type === "thinking") out.push(b.thinking);
			else if (b.type === "toolCall") strings(b.arguments, out);
		}
	}
	return out;
}

const tex = String.raw`\nabla f(x) \in \mathbb{R}^{m \times n}`;
const doubled = `$${tex}$`.replace(/\\/g, "\\\\");

/** Hand-built adversarial corpus. */
const ADVERSARIAL: string[] = [
	"",
	"plain prose, no math",
	// nested / mismatched dollars
	"$a$ and $$b$$ and $$$c$$$",
	"$a $b$ c$",
	"$$ $x$ $$",
	"$x$$y$",
	"$$\nx $ y\n$$",
	"$$ meta\n\\forall\n$$$$",
	"$$\n\fx\n  $$  \r\n",
	"$$\n\fx\n    $$",
	"$$\n\fx\n\t\t\t$$",
	"$$\n\fx\n$$ trailing",
	"$$\n\fx\n$",
	"$$ has $ dollar\n\fx\n$$",
	"   $$\n\fx\n$$",
	"text $$\n\fx\n$$",
	// escaped dollars
	"It costs $x = \\$5$ at market.",
	"$\\$3 + \\text{\\$}4 = \\$7$ exactly.",
	"$a\\\\$b$ tail",
	"$a\\\\\\$b$ tail",
	"\\$5 and \\$10, then $5 and $10.",
	"\\\\$x\\$y$",
	"$x\\$",
	"$$x = \\$5$$",
	"$a$ costs $5\\$10$ and $b$",
	"$\\$$$",
	// legacy delimiters
	"a \\(x^2\\) b",
	"\\(\\)",
	"\\(   \\)",
	"\\( \t x \n \\)",
	"text\n\n\\[\n\\int x\n\\]\n\nmore",
	"mid \\[x^2\\] para",
	"- item\n  \\[\n  x^2\n  \\]\n- next",
	"  \\[ a \n\n  b\u00a0\n\u2028 c \\]",
	"\t\\[x\\] tail",
	"\\[x\\]\r\nnext",
	"escaped \\\\( and \\\\[ stay",
	"\\\\\\(x\\)",
	"partial \\[ mid-stream",
	"\\[ partial\n\nbut \\(ok\\)",
	"\\(a `b` c\\)",
	"\\(x\\]\\)",
	"\\[\np $a\neq b$\n\\]",
	"\\(p\to q, \rho\\)",
	"\\[\n\x0corall\n\\right\n\\]",
	"\\(\\\\nabla\\)",
	"\\[\n\\\\nabla \\\\\\\\, \\\\\\nabla\n\\]",
	"\\(x\\) $\x0corall$ \\(\\$\\)",
	// code fences and inline code
	"```js\n\\(x\\) and \\[y\\]\n```\n\\(z\\)",
	"   ```\n$\fx$\n   ```\n$\fy$",
	"    ```\n$\fx$\n```",
	"~~~~\n$\\\\nabla$\n~~~\n~~~~~ \t\n$\\\\nabla$",
	"```\n$\fx$\n```\r\n$\fy$",
	"``\n$\fx$\n``",
	"```tex\n" + doubled + "\n```",
	"```unclosed\n$\\\\nabla$ \\(x\\)",
	"run `\\(x\\)` locally",
	"``a ` b`` \\(x\\)",
	"`unclosed \\(x\\)",
	"```` ``` \\(x\\)",
	"Literal `$\x0corall x$`.\n\nReal $\x0corall x$.",
	"`" + doubled + "` and " + doubled,
	"x\n```\n\\(y\\)\n```",
	// currency
	"It costs $5 and $10 more. $$big$$ sums too.",
	"$5, $10, $15",
	"Prices: $3.50 - $4.25",
	// over-escaped commands
	doubled,
	`$${tex}$`.replace(/\\/g, "\\\\\\\\"),
	"$\\\\frac{1}{2}$",
	"$$\n\\\\frac{a}{b} \\\\\\\\ 2\n$$",
	"$a \\\\\\nabla b$",
	"$a \\\\ 2 \\\\& 3 \\\\[6pt] 4$",
	"$\\\\|u\\\\|_2 a\\\\,b a\\\\;b a\\\\:b a\\\\!b$",
	"$\\\\1 \\\\é \\\\_$",
	"path C:\\\\Users\\\\amos",
	"$\\\\nabla",
	"$$A = \\\\begin{pmatrix}\n1 & 2\n\\\\end{pmatrix}$$",
	"\\\\",
	"\\",
	"$",
	"$$",
	"`",
	// debris
	"$\beta$ $\to$ $\neq$ $\x0barphi$ $\x0corall$ $\rho$",
	"Compare:\n$$\n\x0barphi, p \neq q\n$$",
	"Compare:\n$$\n\\left(x \right), \to\n$$",
	"Pasted:\t\x0cb. \\$\x0corall x$. A good $x$.",
	"$\x0corall",
	"$\x0corall$$",
	"$$\x0corall$",
	"Inline $$p\neq q$$.",
	"$$\n\x0corall x\n$$$",
	"$p\to q, \rho$",
	"\r\n$\fx$\r\n",
	// unicode
	"$α + β = \\gamma$ 😀 \\(😀\\x\\) `😀`",
	"\\[ 𝔸 \u3000\n\u3000 𝔹 \\]",
	"- 😀\n  \\[\n 😀 \u2029 x\n  \\]",
	"\ufeff\\(\ufeffx\ufeff\\)",
	"$x = \\$😀$",
	"$😀\x0corall$ $$\n😀\\\\nabla\n$$",
	// CRLF
	"line one\r\n\\[\r\nx\r\n\\]\r\nline two",
	"- item\r\n  \\[\r\n  x\r\n  \\]",
	"$$\r\n\x0corall\r\n$$\r\n",
	"$$\r\n\\\\nabla\r\n$$\r\n",
	"```\r\n\\(x\\)\r\n```\r\n\\(y\\)",
];

/** All four functions over both golden chats and the adversarial corpus. */
export default () => {
	const seen = new Set<string>();
	const rows: Array<{ source: string; input: string; outputs: Record<string, string> }> = [];
	const add = (source: string, input: string) => {
		if (seen.has(input)) return;
		seen.add(input);
		rows.push({
			source,
			input,
			outputs: {
				transformMathDelimiters: transformMathDelimiters(input),
				repairMathForDisplay: repairMathForDisplay(input),
				restoreMathEscapes: restoreMathEscapes(input),
				healOverescapedCommands: healOverescapedCommands(input),
			},
		});
	};
	for (const id of [TEACH_CHAT, PRACTICE_CHAT]) for (const t of chatTexts(id)) add(id, t);
	for (const t of ADVERSARIAL) add("adversarial", t);
	return { "math.delimiters": rows };
};
