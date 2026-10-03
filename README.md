# blank_

**Made using AI (OpenAI Codex). Open source under the [MIT license](LICENSE).**

A quiet native Rust app for writing in Typst. Write, edit source, and preview typeset pages; documents stay ordinary local `.typ` files. This branch uses egui/eframe without a webview, JavaScript or Qt.

The Rust implementation is a prototype. It includes a structured, source-preserving editor, shared undo, macOS menus, a contents sidebar, inline `/` commands, Cmd-K, syntax-colored source editing, and PDF preview/export. Some features of the earlier application still need porting; see [current validation and boundaries](docs/acceptance.md).

## Build and run

Requires Rust 1.98 or newer. On macOS, install Xcode Command Line Tools; Python 3 is used for the compiler integration check. No separate Typst installation is needed.

```sh
bash scripts/bootstrap.sh
bash scripts/dev.sh --demo       # debug app, optimized compiler
bash scripts/build.sh            # release app bundle
bash scripts/build.sh --debug    # faster app iteration
bash scripts/check.sh
```

On macOS the packaged app is `build/bin/blank-native.app`. Its separate name allows existing builds to remain usable during evaluation. On other platforms, the build script places both executables in `target/release/` (or the app in `target/debug/` with `--debug`). macOS is the platform currently exercised.

Standard Cargo commands work from the repository root:

```sh
cargo check
cargo test --workspace
cargo run -- --demo
cargo run -- path/to/document.typ
```

Build the helper with `cargo build --release -p writer-helper` before previewing. The development script does this automatically; `BLANK_HELPER` can specify an explicit helper executable.

Use ⌘1 / ⌘2 / ⌘3 for Write / Source / Preview and ⌘K for commands. Tutorial in the native Help menu opens an editable copy of [the original tutorial](examples/Tutorial.typ). The tutorial is preserved exactly and includes instructions for features still awaiting a Rust port.

## Project structure

| Path | Purpose |
|---|---|
| `src/` | Native desktop UI, rich editor adapter, menus, typography and preview worker |
| `crates/document/` | GUI-independent Typst source model and editing transactions |
| `crates/typst-helper/` | Background Typst compiler, PDF/PNG rendering and source maps |
| `tests/` | Compiler protocol and rendering integration checks |
| `examples/` | Original tutorial and sample document assets |
| `tools/library-assessment/` | Isolated alternative editor-model evaluation, outside the application workspace |
| `docs/` | Usage, validation and GUI/editor library assessment |

One root Cargo workspace, lockfile and toolchain configuration cover the application and compiler. Go/Wails, the web frontend, and their build/test configuration are removed from this branch; the previous implementation is preserved on `codex/legacy-go` and in Git history.

Read [the guide](docs/guide.md) and [library assessment](docs/native-assessment.md). Contributions are welcome; run `bash scripts/check.sh` before submitting changes. Dependencies retain their own licenses.
