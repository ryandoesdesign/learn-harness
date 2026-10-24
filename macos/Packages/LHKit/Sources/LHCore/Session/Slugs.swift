import Foundation

// The two filename slugs of the TS app: download.ts `slugFilename` (demo
// downloads) and the markdown export route's `slugify`.

/// Lowercase, NFKD with combining marks folded, runs of non-[a-z0-9] → "-",
/// trimmed, capped at 64; empty → "demo".
public func slugFilename(_ title: String) -> String {
	let folded = String(String.UnicodeScalarView(title.lowercased().decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !(0x300...0x36F).contains($0.value) }))
	let slug = asciiSlug(folded).jsSlice(0, 64)
	return slug.isEmpty ? "demo" : slug
}

/// The session export filename stem (route.ts `slugify`): lowercase, NFKD,
/// runs of non-[a-z0-9] → "-", trimmed; empty → "session".
public func sessionExportSlug(_ title: String) -> String {
	let slug = asciiSlug(title.lowercased().decomposedStringWithCompatibilityMapping)
	return slug.isEmpty ? "session" : slug
}

/// `.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")`.
private func asciiSlug(_ s: String) -> String {
	var out = ""
	var inRun = false
	for scalar in s.unicodeScalars {
		if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
			out.unicodeScalars.append(scalar)
			inRun = false
		} else if !inRun {
			out.append("-")
			inRun = true
		}
	}
	return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}
