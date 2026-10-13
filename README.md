# blank_

A quiet native macOS editor for [Typst](https://typst.app). **Write** lets you edit formatted text, **Source** gives you direct access to Typst, and **Preview** shows the typeset PDF. All three are views of the same document.

Your work stays in ordinary local `.typ` files, including multi-file projects with includes, imports and assets. Automatic draft saving helps keep your work safe.

Typst Universe packages download automatically on first use and remain available offline in `~/Library/Caches/blank_/typst/packages`. **Settings → Typst packages → Clear Package Cache** removes blank_’s downloads; packages are downloaded again when needed. Packages installed by the Typst CLI or bundled in a project's `packages` directory remain available and are not removed.

Zotero integration supports reference insertion and refresh, BibLaTeX and Hayagriva bibliographies, custom CSL styles and bibliography conversion.

Use `/` for blocks and objects, **⌘K** for commands and **⌘1 / ⌘2 / ⌘3** to switch views. For a guided tour, open **Help → Tutorial**.

![blank_ with a garden photograph, heading outline, inline formatting and color palettes](Resources/Screenshots/editor.jpg)

## Download

Get the [latest release](https://github.com/gagarine/blank_/releases) for Apple Silicon. Current development builds require macOS 27 or newer; earlier releases may support older versions. Automatic updates are not available yet.

Releases are not notarized. If macOS blocks blank_, click **Done**, then **System Settings → Privacy & Security → Open Anyway**. [Apple’s instructions](https://support.apple.com/en-us/102445).

## Development

Built with SwiftUI, AppKit and the official Typst 0.15.1 parser and compiler. Local builds and checks require macOS 27 or newer, Swift 6 with a macOS 27 or newer SDK, Rust 1.98.1 (pinned) and Python 3.

```sh
bash scripts/build.sh release  # omit release for debug
open build/blank_.app
bash scripts/check.sh
```

Quit and reopen after rebuilding. Native checks need an unlocked desktop session. See [AGENTS.md](AGENTS.md) for architecture, build and verification conventions.

To repeat the draft restoration checks without rebuilding, run `bash scripts/check-drafts.sh build/blank_.app 10`. Each sequence uses disposable recovery data and fresh AppKit window state, and waits for native snapshot writes before inspecting their exact source and dependencies.

[CI](.github/workflows/build-macos.yml) checks macOS 27 using GitHub’s `xcode-27` runner. Publishing a `vX.Y.Z` release attaches the Apple Silicon app and checksum after the build and checks pass. Apps are ad-hoc signed; Intel support is unverified.

[Issues](https://github.com/gagarine/blank_/issues) · [MIT](LICENSE) · Built with OpenAI Codex.
