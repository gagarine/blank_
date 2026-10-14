# blank_

A quiet macOS editor for [Typst](https://typst.app), for writing documents and turning them into polished PDFs. Edit formatted text, work directly with the source, or preview the finished pages—all in one app.

## Features

- **Three views, one document.** Switch between **Write**, **Source** and **Preview**, with shared editing history and Undo/Redo.
- **Comfortable writing.** Format text, add headings and lists, insert images, and edit tables directly in your document. Collapse code blocks when you want to concentrate on the prose.
- **An outline that helps you move around.** Navigate headings, collapse sections, and drag sections to reorganize your writing.
- **Search and page navigation.** Find text in your writing or PDF, browse page thumbnails, and use Contact Sheet to see several pages at once.
- **Templates with previews.** Browse your own templates and Typst Universe in **File → Templates…**. See thumbnails, flip through preview pages, and read each template’s documentation and author information. Create your own editable copy or save a document as a reusable template.
- **Local files and projects.** Keep your work in ordinary Typst files, with related documents and images together. Automatic draft saving and reopening help you pick up where you left off.
- **References with Zotero.** Search your personal and group libraries, insert and refresh citations, and choose a bibliography style.
- **PDF export and sharing.** Preview your pages as you write, then export a PDF or share it from the app.
- **Automatic package downloads.** Typst packages download when needed and stay available offline. Remove the app’s downloads through **Settings → Typst packages → Clear Package Cache**.

Use `/` for blocks and objects, **⌘K** for commands and **⌘1 / ⌘2 / ⌘3** to switch views. For a guided tour, open **Help → Tutorial**.

![blank_ with a garden photograph, heading outline, inline formatting and color palettes](Resources/Screenshots/editor.jpg)

## Download

Get the [latest release](https://github.com/gagarine/blank_/releases) for Apple Silicon. Current development builds require macOS 27 or newer; earlier releases may support older versions. Automatic updates are not available yet.

If macOS blocks blank_, click **Done**, then **System Settings → Privacy & Security → Open Anyway**. [Apple’s instructions](https://support.apple.com/en-us/102445).

## Development

Built with SwiftUI, AppKit and the official Typst 0.15.1 parser and compiler. Local builds and checks require macOS 27 or newer, Swift 6 with a macOS 27 or newer SDK, Rust 1.98.1 (pinned) and Python 3.

### Build and verification

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

Rust parser unit tests and compiler/package integration tests remain in their Cargo crates and run in background checks. CI runs `check-all.sh`, covering every category. Test hosts use disposable recovery/projects/package caches and an explicit `BLANK_TEMP_DIR` cleaned on failure (AppKit can ignore `TMPDIR`), run from signed relocated bundles without development library paths, and preserve clipboard, recents and existing test preferences. The background host prohibits activation/window ordering and verifies it never becomes active or displays a window; it never writes the system clipboard.

Swift Testing was verified with the macOS 27 CLT compiler. Its default module scan misses the bundled macro plugin, so `check-unit.sh` explicitly loads the plugin paired with the selected compiler when present. XCTest cannot be imported with this CLT installation, and `xcodebuild`/XCUIAutomation require full Xcode. The native integration/UI harness remains for those categories, with distinct targets, folders and commands; there is no silent reduction of native keyboard/focus assertions. An eventual XCUIAutomation migration needs a real Xcode UI-test runner and a fresh compatibility check. [Swift Testing](https://developer.apple.com/xcode/swift-testing/) and [XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation) describe the supported frameworks.

UI scenarios that depend on app-wide focus run in separate processes. The harness waits for real AppKit field/sheet transitions; the injected hover fixture temporarily suspends automatic cursor-rectangle refresh in its window while exercising native mouse/cursor handlers and foreground focus. Native events exercise AppKit input paths, but real IME candidate panels, VoiceOver, bidirectional navigation, live Zotero and broader file/window/object scenarios remain unverified. Large-table editing and full Source reprojection still need performance work.

Ordinary builds contain no acceptance fixtures. `BLANK_BUILD_CHECKS=1` adds verification targets and enables their `@testable` imports; scripts set it automatically. Verification executables run inside temporary app copies so native document APIs and bundled compiler lookup are real. Do not run their raw Swift executables against user data.

### Packages and templates

Packages and the Universe catalogue are cached in `~/Library/Caches/blank_/typst/packages`. Clear Package Cache removes this app-owned cache, including the catalogue, without removing packages installed by the Typst CLI or vendored in a project's `packages` directory.

Universe uses the official index API and selects the latest version compatible with the bundled compiler. The catalogue refreshes after 24 hours or manually, with a saved-catalogue fallback offline. Published row thumbnails use a bounded memory cache; PDF previews compile on selection and display one page at a time. Readme and About use published documentation and metadata. Catalogue, preview and creation work can be cancelled; a failed preview does not prevent creating an editable copy.

Create Document copies all starter files and assets, preserving the declared entry and version-pinned imports. Downloaded and local templates work offline when their imports are cached. New Document always starts empty. Zotero integration supports BibLaTeX and Hayagriva bibliographies, custom CSL styles and bibliography conversion.

### Releases

[CI](.github/workflows/build-macos.yml) checks macOS 27 using GitHub’s `xcode-27` runner. Publishing a `vX.Y.Z` release attaches the Apple Silicon app and checksum after the build and checks pass. Apps are ad-hoc signed and are not notarized; Intel support is unverified.

[Issues](https://github.com/gagarine/blank_/issues) · [MIT](LICENSE) · Built with OpenAI Codex.
