# blank_

A quiet native macOS editor for [Typst](https://typst.app), built with SwiftUI and AppKit. Documents stay ordinary local `.typ` projects.

Use `/` for blocks and objects, **⌘K** for commands and **⌘1 / ⌘2 / ⌘3** for Write / Source / Preview.

For a guided tour, open **Help → Tutorial**.

![blank_ with a garden photograph, heading outline, inline formatting and color palettes](Resources/Screenshots/editor.jpg)

## Download

Get the [latest release](https://github.com/gagarine/blank_/releases) for Apple Silicon and macOS 26+. Automatic updates are not available yet.

Releases are not notarized. If macOS blocks blank_, click **Done**, then **System Settings → Privacy & Security → Open Anyway**. [Apple’s instructions](https://support.apple.com/en-us/102445).

## Writing

**Write** lets you edit formatted text, **Source** gives you direct access to the underlying Typst, and **Preview** shows the typeset PDF. These are three views of the same document, so you can move between drafting, adjusting the source and checking the result.

## Projects and references

Supports `.typ` files and multi-file projects with includes, imports and assets. Packages must already be cached or vendored in `packages/`.

Drafts autosave privately, with optional restoration on launch in Settings.

Zotero integration supports reference insertion and refresh, BibLaTeX and Hayagriva bibliographies, custom CSL styles and bibliography conversion.

## Development

Requires Swift 6 with a macOS 26/27 SDK, Rust 1.98.1 (pinned) and Python 3.

```sh
bash scripts/build.sh release  # omit release for debug
open build/blank_.app
bash scripts/check.sh
```

Quit and reopen after rebuilding. Native checks need an unlocked desktop session.

Uses the official Typst 0.15.1 parser and compiler. See [AGENTS.md](AGENTS.md) for architecture, build and verification conventions.

[CI](.github/workflows/build-macos.yml) checks macOS 26/27. Publishing a `vX.Y.Z` release attaches the Apple Silicon app and checksum after both builds pass. Apps are ad-hoc signed; Intel support is unverified.

[Issues](https://github.com/gagarine/blank_/issues) · [MIT](LICENSE) · Built with OpenAI Codex.
