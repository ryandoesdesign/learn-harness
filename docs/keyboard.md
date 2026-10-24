# Keyboard shortcuts

## The native macOS app (M8)

Decided 2026-10-24 (`docs/native-macos-m8.md`). The native app follows Mac
conventions.

- **One table:** `macos/Aster/AppCommands.swift` (`AppShortcut`)
  drives the menus and Help → Keyboard Shortcuts. `ShortcutTests` checks
  that no two items share a key and none takes a standard macOS shortcut.
- **Rebinding:** none in the app. Every shortcut is a menu item, so macOS
  rebinds it by title under System Settings → Keyboard → Keyboard
  Shortcuts → App Shortcuts.
- **⌘ only:** Ctrl is never treated as ⌘, so the Mac's text keys (⌃K, ⌃B…)
  keep working.

| Menu | Item | Key |
|---|---|---|
| File | New Session / New Practice Session | ⌘N / ⇧⌘N |
| Edit | Find… / Find Next / Find Previous | ⌘F / ⌘G / ⇧⌘G |
| Edit | Search Sessions | ⇧⌘F |
| Edit | Dictate / Stop Dictating | ⌘D |
| View | Show / Hide Sidebar | ⌃⌘S |
| View | Expand / Collapse Your Thinking | ⌘T |
| Session | Rename… (also Return on a sidebar row) | |
| Session | Model and Effort… | ⌘K |
| Session | Next Problem | ⌘↩ |
| Window | Knowledge Graph | ⌥⌘G |
| Help | Keyboard Shortcuts | |

Not menu items: the question dock's ↑/↓, Space, ←/→ and Return; Return
submits and ⇧Return adds a line in every field; Return with no field
focused submits practice thinking or asks for the next problem. Esc is
layered: dictation (discard), Find, an overlay, then "Dismiss this
question?", "Discard this problem?" or "Abort this turn?". Tab and ⇧Tab
move focus (TS's ⇧Tab effort cycle is ⌘K here); TS's ⌘B, ⌘G (graph), F2
and the ? cheat sheet are replaced by the rows above.
