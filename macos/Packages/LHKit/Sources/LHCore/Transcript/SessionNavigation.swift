import Foundation

// Port of src/core/session-navigation.ts — message-granular graph links.

/// The transcript anchor for a native message.
public func messageAnchorId(_ messageId: String) -> String {
	"message-\(messageId)"
}

/// The native message id an anchor names, or nil.
public func messageIdFromAnchor(_ anchor: String) -> String? {
	let a = anchor.hasPrefix("#") ? String(anchor.dropFirst()) : anchor
	let decoded = a.removingPercentEncoding ?? a
	guard decoded.hasPrefix("message-"), decoded.count > "message-".count else { return nil }
	return String(decoded.dropFirst("message-".count))
}

/// projectView's text-part identity is `<native message ID>-t<text index>`.
public func textPartMessageId(_ partId: String?) -> String? {
	guard let partId, let m = partId.wholeMatch(of: /(.*)-t\d+/) else { return nil }
	let id = String(m.1)
	return id.isEmpty ? nil : id
}

/// One anchor per native teacher message, at its first non-empty prose part:
/// native message id → that part's id.
public func firstSourceTextParts(_ messages: [ViewMessage]) -> [String: String] {
	var first: [String: String] = [:]
	for message in messages where message.role == .assistant {
		for part in message.parts {
			guard part.kind == .text, let text = part.text, !text.jsTrimmed.isEmpty, let id = part.id else { continue }
			if let messageId = textPartMessageId(id), first[messageId] == nil { first[messageId] = id }
		}
	}
	return first
}
