# blank_

A quiet native macOS editor for [Typst](https://typst.app). **Write** lets you edit formatted text, **Source** gives you direct access to Typst, and **Preview** shows the typeset PDF. All three are views of the same document.

Your work stays in ordinary local `.typ` files, including multi-file projects with includes, imports and assets. Automatic draft saving helps keep your work safe.

Typst Universe packages download automatically on first use and remain available offline in `~/Library/Caches/blank_/typst/packages`. **Settings → Typst packages → Clear Package Cache** removes blank_’s downloads; packages are downloaded again when needed. Packages installed by the Typst CLI or bundled in a project's `packages` directory remain available and are not removed.

**File → Templates…** offers **Local** and **Universe** with a shared search field. Universe lists the latest version compatible with the bundled Typst compiler and loads published thumbnails for visible rows into a bounded memory cache. Select a template to load its preview automatically. Native previous/next controls show one complete page at a time; Readme and About appear directly below, including authors, license, release dates, minimum Typst version and repository when supplied by Universe. **Create Document** copies every starter file and asset into an independent draft, preserving its declared entry and version-pinned imports. **Save as Template…** adds your copy to Local. New Document stays empty.

Universe catalogue and packages share the cache above. The catalogue refreshes after 24 hours, can be refreshed manually, and falls back to the saved catalogue when offline. Downloaded templates and local templates work offline when their imports are cached. Clear Package Cache also clears the saved catalogue. Catalogue, preview and creation work can be cancelled; preview failure still allows creating an editable copy.

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
bash scripts/check.sh          # background: unit + integration
bash scripts/check-ui.sh       # explicit interactive UI suite
bash scripts/check-all.sh      # all categories, including UI
```

Quit and reopen after rebuilding. Default checks run without activation, visible windows or desktop keyboard input. Native integration still needs a logged-in window-server session. UI checks explicitly activate the disposable test app and need an unlocked desktop; quit the existing `/tmp/blank-resize-ui/blank_.app` fixture first. See [AGENTS.md](AGENTS.md) for architecture, build and verification conventions.

| Category | Targets and files | Scope |
| --- | --- | --- |
| Unit | `BlankUnitTests`, `Tests/Unit` | Canonical model/source, Unicode mapping, history, editing transactions and structured clipboard data. All 38 existing model checks use Swift Testing. |
| Integration | `BlankIntegrationTests` / `BlankIntegrationChecks`, `Tests/Integration` | Files, projects, recovery/relaunches, packages, compiler protocol, PDF/export/share revisions, template storage and previews, mocked citation APIs and AppKit attributed text/layout that need no foreground. |
| UI | `BlankUITests` / `BlankUIChecks`, `Tests/UI` | Actual native key paths, shortcuts, selection, focus, navigation, sheets/windows, deletion across block boundaries, marked-text composition, tables and shared Undo/Redo. |

Rust parser unit tests and compiler/package integration tests remain in their Cargo crates and run in background checks. CI runs `check-all.sh`, covering every category. Test hosts use disposable recovery/projects/package caches, run from signed relocated bundles without development library paths, and preserve clipboard, recents and existing test preferences. The background host prohibits activation/window ordering and verifies it never becomes active or displays a window; it never writes the system clipboard.

Swift Testing was verified with the macOS 27 CLT compiler. Its default module scan misses the bundled macro plugin, so `check-unit.sh` explicitly loads the plugin paired with the selected compiler when present. XCTest cannot be imported with this CLT installation, and `xcodebuild`/XCUIAutomation require full Xcode. The native integration/UI harness remains for those categories, with distinct targets, folders and commands; there is no silent reduction of native keyboard/focus assertions. An eventual XCUIAutomation migration needs a real Xcode UI-test runner and a fresh compatibility check. [Swift Testing](https://developer.apple.com/xcode/swift-testing/) and [XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation) describe the supported frameworks.

UI scenarios that depend on app-wide focus run in separate processes. The harness waits for real AppKit field/sheet transitions; the hover fixture positions its disposable window under the stationary pointer. Native events exercise AppKit input paths, but real IME candidate panels, VoiceOver, bidirectional navigation, live Zotero and broader file/window/object scenarios remain unverified. Large-table editing and full Source reprojection still need performance work.

Ordinary builds contain no acceptance fixtures. `BLANK_BUILD_CHECKS=1` adds verification targets and enables their `@testable` imports; scripts set it automatically. Verification executables run inside temporary app copies so native document APIs and bundled compiler lookup are real. Do not run their raw Swift executables against user data.

[CI](.github/workflows/build-macos.yml) checks macOS 27 using GitHub’s `xcode-27` runner. Publishing a `vX.Y.Z` release attaches the Apple Silicon app and checksum after the build and checks pass. Apps are ad-hoc signed; Intel support is unverified.

[Issues](https://github.com/gagarine/blank_/issues) · [MIT](LICENSE) · Built with OpenAI Codex.
