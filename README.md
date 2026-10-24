# Aster

Aster uses AI agents to plan and teach lessons from your current understanding to your goal. It builds a detailed picture of what you understand and how you reason. That picture is updated as you learn.

A native macOS app (Swift 6, SwiftUI).

## Build

Requires macOS 27, Xcode with the macOS 27 SDK, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen            # regenerates Aster.xcodeproj from project.yml
open Aster.xcodeproj
```

Run the `Aster` scheme. Add your Anthropic API key when the first session starts; it's stored in your Keychain.

## Test

```bash
xcodebuild test -project Aster.xcodeproj -scheme Aster -destination 'platform=macOS'
swift test --package-path Packages/LHKit
python3 -B -m unittest discover -s tests/skills
```

## Layout

- `Aster/` — the app; `AsterTests/` — hosted tests.
- `Packages/LHKit/` — the domain, store, agent and rendering packages.
- `skills/aster/` — an Agent Skill that reads Aster's database read-only.
- `docs/` — the native build notes (`native-macos-plan.md`, M1–M8), keyboard shortcuts, and the teaching approach (`vision.md`, `teaching-methodology.md`, `probe-teach-split.md`).

## License

[AGPL-3.0](LICENSE)
